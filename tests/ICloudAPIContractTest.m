#import <Foundation/Foundation.h>
#import <FileProvider/FileProvider.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <xattr_flags.h>
#include <unistd.h>

static void RemoveContractItemIfPresent(NSURL *url);
static int RunChild(NSArray *arguments);
static BOOL VersionsContainPayload(NSArray *versions, NSData *payload);
static NSFileVersion *CoordinatedVersionForIdentifier(NSURL *url, id identifier,
	NSError **outError);

static NSUInteger failures = 0;
static NSUInteger skips = 0;

static void Report(NSString *kind, NSString *contract, NSString *detail) {
	@synchronized ([NSProcessInfo processInfo]) {
		fprintf(stdout, "%s %s%s%s\n", [kind UTF8String], [contract UTF8String],
			[detail length] ? " " : "", [detail UTF8String]);
		fflush(stdout);
		if ([kind isEqualToString:@"FAIL"])
			failures++;
		else if ([kind isEqualToString:@"SKIP"])
			skips++;
	}
}

static NSString *ErrorCode(NSError *error) {
	if (!error)
		return @"none";
	NSError *underlying = [[error userInfo] objectForKey:NSUnderlyingErrorKey];
	return underlying ? [NSString stringWithFormat:@"%@/%ld underlying=%@/%ld", [error domain],
		(long)[error code], [underlying domain], (long)[underlying code]] :
		[NSString stringWithFormat:@"%@/%ld", [error domain], (long)[error code]];
}

static void ReportError(NSString *kind, NSString *contract, NSError *error) {
	Report(kind, contract, [NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
}

static BOOL WaitFor(NSTimeInterval timeout, BOOL (^condition)(void)) {
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	do {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		BOOL done = condition();
		[pool drain];
		if (done)
			return YES;
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	} while ([deadline timeIntervalSinceNow] > 0.0);
	return NO;
}

static BOOL WaitSemaphore(dispatch_semaphore_t semaphore, NSTimeInterval timeout) {
	return WaitFor(timeout, ^BOOL{
		return dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0;
	});
}

static NSError *WaitForAsyncError(NSTimeInterval timeout, void (^starter)(void (^)(NSError *)));
static NSFileVersion *WaitForAsyncVersion(NSTimeInterval timeout,
	void (^starter)(void (^)(NSFileVersion *, NSError *)), NSError **outError);
static NSError *PauseSyncWhenStable(NSURL *url, NSTimeInterval timeout) API_AVAILABLE(macos(26.0));
static BOOL ProviderIdentitiesEqual(NSDictionary *first, NSDictionary *second);
static BOOL WaitForMarker(NSURL *sessionURL, NSString *name, NSTimeInterval timeout);
static BOOL WriteUploadedMarker(NSURL *sessionURL, NSString *name, NSTimeInterval timeout,
	NSError **outError);
static BOOL IsDownloadStatus(NSURL *url, NSURLUbiquitousItemDownloadingStatus status);
static BOOL WaitUntilUploaded(NSURL *url, NSTimeInterval timeout);
static BOOL WaitUntilCurrent(NSURL *url, NSTimeInterval timeout);
static BOOL WaitUntilNotDownloaded(NSURL *url, NSTimeInterval timeout);
static NSDictionary *FileIdentityObservation(NSURL *url, NSError **outError);

static NSURL *FreshURL(NSURL *url) {
	return [NSURL fileURLWithPath:[url path] isDirectory:[url hasDirectoryPath]];
}

static id ResourceValue(NSURL *url, NSURLResourceKey key, NSError **outError) {
	id value = nil;
	NSError *error = nil;
	if (![[FreshURL(url) absoluteURL] getResourceValue:&value forKey:key error:&error] && outError)
		*outError = error;
	return value;
}

static NSData *PatternData(NSUInteger length, uint8_t seed) {
	NSMutableData *data = [NSMutableData dataWithLength:length];
	uint8_t *bytes = [data mutableBytes];
	for (NSUInteger i = 0; i < length; i++)
		bytes[i] = (uint8_t)(seed + i * 31U);
	return data;
}

static NSData *UniquePatternData(NSUInteger length, uint8_t seed) {
	NSMutableData *data = [[PatternData(MAX(length, (NSUInteger)64), seed) mutableCopy] autorelease];
	NSData *identifier = [[[[NSUUID UUID] UUIDString] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	[data replaceBytesInRange:NSMakeRange(0, MIN([identifier length], [data length]))
		withBytes:[identifier bytes]];
	return data;
}

static NSError *PhaseError(NSInteger phase, NSError *underlying) {
	NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
	if (underlying)
		[userInfo setObject:underlying forKey:NSUnderlyingErrorKey];
	return [NSError errorWithDomain:@"NVAPIContractTest.FoundationReplacement"
		code:phase userInfo:userInfo];
}

static BOOL CoordinatedCreateDirectory(NSURL *url, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block BOOL created = NO;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateWritingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		created = [[NSFileManager defaultManager] createDirectoryAtURL:newURL withIntermediateDirectories:NO attributes:nil error:&accessError];
	}];
	if (!created && outError)
		*outError = accessError ?: coordinationError;
	return created;
}

static BOOL CoordinatedWriteWithOptions(NSURL *url, NSData *data,
	NSFileCoordinatorWritingOptions coordinationOptions, NSDataWritingOptions dataOptions,
	NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block BOOL wrote = NO;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateWritingItemAtURL:url options:coordinationOptions error:&coordinationError byAccessor:^(NSURL *newURL) {
		wrote = [data writeToURL:newURL options:dataOptions error:&accessError];
	}];
	if (!wrote && outError)
		*outError = accessError ?: coordinationError;
	return wrote;
}

static BOOL CoordinatedWrite(NSURL *url, NSData *data, NSError **outError) {
	return CoordinatedWriteWithOptions(url, data, NSFileCoordinatorWritingForReplacing,
		NSDataWritingAtomic, outError);
}

static BOOL CoordinatedInPlaceWrite(NSURL *url, NSData *data, NSError **outError) {
	return CoordinatedWriteWithOptions(url, data, 0, 0, outError);
}

static BOOL RawWrite(NSURL *url, NSData *data, NSError **outError) {
	int descriptor = open([url fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (descriptor < 0) {
		if (outError)
			*outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
		return NO;
	}
	const uint8_t *bytes = [data bytes];
	NSUInteger remaining = [data length];
	BOOL wrote = YES;
	while (remaining) {
		ssize_t count = write(descriptor, bytes, remaining);
		if (count < 0) {
			if (errno == EINTR)
				continue;
			wrote = NO;
			break;
		}
		bytes += count;
		remaining -= (NSUInteger)count;
	}
	int savedErrno = wrote ? 0 : errno;
	if (close(descriptor) < 0 && wrote) {
		wrote = NO;
		savedErrno = errno;
	}
	if (!wrote && outError)
		*outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErrno userInfo:nil];
	return wrote;
}

static NSString *SyncableUUIDXAttrName(void) {
	char *encodedName = xattr_name_with_flags("com.notationalvelocity.note-uuid.v1",
		XATTR_FLAG_SYNCABLE);
	if (!encodedName)
		return nil;
	NSString *name = [NSString stringWithUTF8String:encodedName];
	free(encodedName);
	return name;
}

static NSData *ContractUUIDData(NSUInteger index) {
	uint8_t bytes[16] = { 'N', 'V', 'X', 'A', 'T', 'T', 'R', 1, 0, 0, 0, 0, 0, 0, 0, 0 };
	for (NSUInteger offset = 0; offset < sizeof(NSUInteger) && offset < 8; offset++)
		bytes[15 - offset] = (uint8_t)(index >> (offset * 8));
	return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSData *XAttrData(NSURL *url, const char *name) {
	const char *path = [url fileSystemRepresentation];
	ssize_t length = getxattr(path, name, NULL, 0, 0, XATTR_NOFOLLOW);
	if (length < 0)
		return nil;
	NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
	return getxattr(path, name, [data mutableBytes], (size_t)length, 0,
		XATTR_NOFOLLOW) == length ? data : nil;
}

static BOOL CoordinatedSetXAttrData(NSURL *url, NSString *name, NSData *data,
	NSError **outError) {
	if (!name) {
		if (outError)
			*outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
		return NO;
	}
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block BOOL wrote = NO;
	__block int accessErrno = 0;
	NSError *coordinationError = nil;
	[coordinator coordinateWritingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		wrote = setxattr([newURL fileSystemRepresentation], [name UTF8String], [data bytes],
			[data length], 0, XATTR_NOFOLLOW) == 0;
		if (!wrote)
			accessErrno = errno;
	}];
	if (!wrote && outError)
		*outError = coordinationError ?: [NSError errorWithDomain:NSPOSIXErrorDomain
			code:accessErrno userInfo:nil];
	return wrote;
}

static NSData *CoordinatedXAttrData(NSURL *url, NSString *name,
	NSFileCoordinatorReadingOptions options, NSError **outError) {
	if (!name) {
		if (outError)
			*outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
		return nil;
	}
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSData *data = nil;
	__block int accessErrno = 0;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:url options:options error:&coordinationError byAccessor:^(NSURL *newURL) {
		data = [XAttrData(newURL, [name UTF8String]) retain];
		if (!data)
			accessErrno = errno;
	}];
	if (!data && outError)
		*outError = coordinationError ?: [NSError errorWithDomain:NSPOSIXErrorDomain
			code:accessErrno userInfo:nil];
	return [data autorelease];
}

static BOOL WaitForXAttr(NSURL *url, NSString *name, NSData *expected,
	NSFileCoordinatorReadingOptions options, NSTimeInterval timeout) {
	return WaitFor(timeout, ^BOOL{
		return [CoordinatedXAttrData(url, name, options, NULL) isEqual:expected];
	});
}

static BOOL CoordinatedWriteWithUUID(NSURL *url, NSData *contents, NSData *uuid,
	NSError **outError) {
	NSString *name = SyncableUUIDXAttrName();
	return name && CoordinatedWrite(url, contents, outError) &&
		CoordinatedSetXAttrData(url, name, uuid, outError);
}

static NSURL *CoordinatedSafeReplaceWithBackupPerformingAccessorAction(NSURL *url, NSData *data,
	NSString *backupName, NSFileManagerItemReplacementOptions options,
	void (^accessorAction)(void), NSString *stagedXAttrName, NSData *stagedXAttrData,
	NSError **outError) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSError *error = nil;
	NSURL *replacementDirectory = [manager URLForDirectory:NSItemReplacementDirectory
		inDomain:NSUserDomainMask appropriateForURL:url create:YES error:&error];
	NSURL *replacementURL = [replacementDirectory URLByAppendingPathComponent:
		[[NSProcessInfo processInfo] globallyUniqueString]];
	if (!replacementDirectory || !replacementURL) {
		if (outError)
			*outError = PhaseError(1, error);
		return nil;
	}
	if (![data writeToURL:replacementURL options:0 error:&error]) {
		if (outError)
			*outError = PhaseError(2, error);
		return nil;
	}
	if (stagedXAttrName && setxattr([replacementURL fileSystemRepresentation],
		[stagedXAttrName UTF8String], [stagedXAttrData bytes], [stagedXAttrData length],
		0, XATTR_NOFOLLOW) != 0) {
		if (outError)
			*outError = PhaseError(21, [NSError errorWithDomain:NSPOSIXErrorDomain
				code:errno userInfo:nil]);
		[manager removeItemAtURL:replacementURL error:NULL];
		return nil;
	}

	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSURL *resultURL = nil;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForReplacing
		writingItemAtURL:replacementURL options:NSFileCoordinatorWritingForMoving error:&coordinationError
		byAccessor:^(NSURL *newURL, NSURL *newReplacementURL) {
			if (accessorAction)
				accessorAction();
			NSURL *candidateURL = nil;
			if ([manager replaceItemAtURL:newURL withItemAtURL:newReplacementURL backupItemName:backupName
				options:options resultingItemURL:&candidateURL error:&accessError])
				resultURL = [candidateURL retain];
		}];
	if (!resultURL && outError)
		*outError = PhaseError(accessError ? 31 : 32, accessError ?: coordinationError);
	if ([manager fileExistsAtPath:[replacementURL path]])
		[manager removeItemAtURL:replacementURL error:NULL];
	return [resultURL autorelease];
}

static NSURL *CoordinatedSafeReplacePerformingAccessorAction(NSURL *url, NSData *data,
	void (^accessorAction)(void), NSError **outError) {
	return CoordinatedSafeReplaceWithBackupPerformingAccessorAction(url, data, nil, 0,
		accessorAction, nil, nil, outError);
}

static NSURL *CoordinatedSafeReplace(NSURL *url, NSData *data, NSError **outError) {
	return CoordinatedSafeReplacePerformingAccessorAction(url, data, nil, outError);
}

static NSURL *CoordinatedSafeReplaceWithBackup(NSURL *url, NSData *data,
	NSString *backupName, NSError **outError) {
	return CoordinatedSafeReplaceWithBackupPerformingAccessorAction(url, data, backupName,
		NSFileManagerItemReplacementWithoutDeletingBackupItem, nil, nil, nil, outError);
}

static NSURL *CoordinatedSafeReplaceWithUUID(NSURL *url, NSData *data, NSData *uuid,
	NSFileManagerItemReplacementOptions options, NSError **outError) {
	return CoordinatedSafeReplaceWithBackupPerformingAccessorAction(url, data, nil, options,
		nil, SyncableUUIDXAttrName(), uuid, outError);
}

static NSData *CoordinatedRead(NSURL *url, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSData *data = nil;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		data = [[NSData alloc] initWithContentsOfURL:newURL options:0 error:&accessError];
	}];
	if (!data && outError)
		*outError = accessError ?: coordinationError;
	return [data autorelease];
}

static NSDictionary *CoordinatedCurrentSnapshot(NSURL *url, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSDictionary *snapshot = nil;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		NSData *data = [NSData dataWithContentsOfURL:newURL options:0 error:&accessError];
		NSFileVersion *version = [NSFileVersion currentVersionOfItemAtURL:newURL];
		id identifier = [version persistentIdentifier];
		NSDictionary *filesystem = FileIdentityObservation(newURL, NULL);
		if (data && identifier)
			snapshot = [[NSDictionary alloc] initWithObjectsAndKeys:
				data, @"bytes", identifier, @"version",
				filesystem ?: (id)[NSDictionary dictionary], @"filesystem", nil];
	}];
	if (!snapshot && outError)
		*outError = accessError ?: coordinationError ?:
			[NSError errorWithDomain:@"NVAPIContractTest" code:EAGAIN userInfo:nil];
	return [snapshot autorelease];
}

static NSArray *CoordinatedUnresolvedVersions(NSURL *url, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSArray *versions = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		versions = [[NSFileVersion unresolvedConflictVersionsOfItemAtURL:newURL] copy];
	}];
	if (!versions && outError)
		*outError = coordinationError ?: [NSError errorWithDomain:@"NVAPIContractTest" code:EAGAIN userInfo:nil];
	return [versions autorelease];
}

static BOOL CoordinatedResolveVersion(NSURL *url, NSFileVersion *version, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block BOOL resolved = NO;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMerging
		error:&coordinationError byAccessor:^(NSURL *newURL) {
		(void)newURL;
		@try {
			[version setResolved:YES];
			resolved = YES;
		} @catch (NSException *exception) {
			accessError = [[NSError errorWithDomain:@"NVAPIContractTest" code:EIO userInfo:
				[NSDictionary dictionaryWithObject:[exception name] forKey:NSLocalizedFailureReasonErrorKey]] retain];
		}
	}];
	if (!resolved && outError) {
		NSError *resultError = accessError ?: coordinationError ?:
			[NSError errorWithDomain:@"NVAPIContractTest" code:EIO userInfo:nil];
		*outError = [[resultError retain] autorelease];
	}
	[accessError release];
	return resolved;
}

static BOOL CoordinatedMove(NSURL *sourceURL, NSURL *destinationURL, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block BOOL moved = NO;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateWritingItemAtURL:sourceURL options:NSFileCoordinatorWritingForMoving
		writingItemAtURL:destinationURL options:NSFileCoordinatorWritingForReplacing error:&coordinationError
		byAccessor:^(NSURL *newSourceURL, NSURL *newDestinationURL) {
			moved = [[NSFileManager defaultManager] moveItemAtURL:newSourceURL toURL:newDestinationURL error:&accessError];
		}];
	if (!moved && outError)
		*outError = accessError ?: coordinationError;
	return moved;
}

static BOOL CoordinatedDelete(NSURL *url, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block BOOL removed = NO;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForDeleting error:&coordinationError byAccessor:^(NSURL *newURL) {
		removed = [[NSFileManager defaultManager] removeItemAtURL:newURL error:&accessError];
	}];
	if (!removed && outError)
		*outError = accessError ?: coordinationError;
	return removed;
}

static NSDictionary *CoordinatedCatalogPerformingAccessorAction(NSURL *directoryURL,
	void (^accessorAction)(void), NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSDictionary *catalog = nil;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:directoryURL options:0
		error:&coordinationError byAccessor:^(NSURL *newURL) {
			if (accessorAction)
				accessorAction();
			NSArray *keys = [NSArray arrayWithObjects:NSURLFileResourceIdentifierKey, NSURLContentModificationDateKey,
				NSURLFileSizeKey, NSURLUbiquitousItemDownloadingStatusKey, nil];
			NSArray *children = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:newURL
				includingPropertiesForKeys:keys options:0 error:&accessError];
			if (!children)
				return;
			NSMutableDictionary *entries = [NSMutableDictionary dictionaryWithCapacity:[children count]];
			for (NSURL *child in children) {
				NSMutableArray *values = [NSMutableArray arrayWithCapacity:[keys count]];
				for (NSURLResourceKey key in keys) {
					id value = nil;
					[child getResourceValue:&value forKey:key error:NULL];
					[values addObject:value ?: [NSNull null]];
				}
				[entries setObject:values forKey:[child lastPathComponent]];
			}
			catalog = [entries copy];
		}];
	if (!catalog && outError)
		*outError = accessError ?: coordinationError;
	return [catalog autorelease];
}

static NSDictionary *CoordinatedCatalog(NSURL *directoryURL, NSError **outError) {
	return CoordinatedCatalogPerformingAccessorAction(directoryURL, nil, outError);
}

static void TestCatalogFenceContracts(NSURL *parentURL) {
	NSURL *directoryURL = [parentURL URLByAppendingPathComponent:@"catalog-fence" isDirectory:YES];
	RemoveContractItemIfPresent(directoryURL);
	NSError *error = nil;
	BOOL created = CoordinatedCreateDirectory(directoryURL, &error);
	NSDictionary *empty = created ? CoordinatedCatalog(directoryURL, &error) : nil;
	Report(empty && [empty count] == 0 ? @"PASS" : @"FAIL", @"AV-03-empty-catalog",
		empty && [empty count] == 0 ? @"empty coordinated catalog was exact" :
		[NSString stringWithFormat:@"count=%lu error=%@", (unsigned long)[empty count], ErrorCode(error)]);

	NSURL *editedURL = [directoryURL URLByAppendingPathComponent:@"edited.txt"];
	NSURL *renamedSourceURL = [directoryURL URLByAppendingPathComponent:@"rename-source.txt"];
	NSURL *deletedURL = [directoryURL URLByAppendingPathComponent:@"deleted.txt"];
	BOOL initialReady = created &&
		CoordinatedWrite(editedURL, [@"before" dataUsingEncoding:NSUTF8StringEncoding], &error) &&
		CoordinatedWrite(renamedSourceURL, [@"rename" dataUsingEncoding:NSUTF8StringEncoding], &error) &&
		CoordinatedWrite(deletedURL, [@"delete" dataUsingEncoding:NSUTF8StringEncoding], &error);
	NSDictionary *before = initialReady ? CoordinatedCatalog(directoryURL, &error) : nil;
	NSURL *renamedURL = [directoryURL URLByAppendingPathComponent:@"renamed.txt"];
	NSURL *createdURL = [directoryURL URLByAppendingPathComponent:@"created.txt"];
	BOOL mutated = before &&
		CoordinatedWrite(editedURL, [@"after-with-a-different-size" dataUsingEncoding:NSUTF8StringEncoding], &error) &&
		CoordinatedMove(renamedSourceURL, renamedURL, &error) &&
		CoordinatedDelete(deletedURL, &error) &&
		CoordinatedWrite(createdURL, [@"create" dataUsingEncoding:NSUTF8StringEncoding], &error);
	NSDictionary *after = mutated ? CoordinatedCatalog(directoryURL, &error) : nil;
	NSSet *expected = [NSSet setWithObjects:@"edited.txt", @"renamed.txt", @"created.txt", nil];
	BOOL detected = before && after && ![before isEqual:after] &&
		[[NSSet setWithArray:[after allKeys]] isEqualToSet:expected];
	Report(detected ? @"PASS" : @"FAIL", @"AV-03-double-catalog-fence",
		detected ? @"create, edit, rename, and delete between exact catalogs changed the snapshot" :
		[NSString stringWithFormat:@"before=%lu after=%lu error=%@",
			(unsigned long)[before count], (unsigned long)[after count], ErrorCode(error)]);
	RemoveContractItemIfPresent(directoryURL);
}

typedef struct __attribute__((packed, aligned(4))) {
	uint32_t length;
	attribute_set_t returned;
	fsobj_type_t objectType;
	uint32_t generationCount;
	uint32_t documentID;
	uint64_t fileID;
} NVContractIdentityAttributes;

static NSDictionary *FileIdentityObservation(NSURL *url, NSError **outError) {
	struct attrlist requested = { 0 };
	requested.bitmapcount = ATTR_BIT_MAP_COUNT;
	requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_OBJTYPE |
		ATTR_CMN_GEN_COUNT | ATTR_CMN_DOCUMENT_ID | ATTR_CMN_FILEID;
	NVContractIdentityAttributes attributes = { 0 };
	int result = getattrlist([url fileSystemRepresentation], &requested, &attributes,
		sizeof(attributes), FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS);
	attrgroup_t required = ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
	if (result < 0 || attributes.length < sizeof(attributes) ||
		(attributes.returned.commonattr & required) != required ||
		attributes.objectType != VREG) {
		if (outError)
			*outError = [NSError errorWithDomain:NSPOSIXErrorDomain
				code:result < 0 ? errno : EINVAL userInfo:nil];
		return nil;
	}
	NSString *volumeUUID = ResourceValue(url, NSURLVolumeUUIDStringKey, NULL);
	return [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithUnsignedLongLong:attributes.fileID], @"fileID",
		[NSNumber numberWithUnsignedInt:(attributes.returned.commonattr & ATTR_CMN_DOCUMENT_ID) ?
			attributes.documentID : 0], @"documentID",
		[NSNumber numberWithUnsignedInt:(attributes.returned.commonattr & ATTR_CMN_GEN_COUNT) ?
			attributes.generationCount : 0], @"generation",
		volumeUUID ?: @"", @"volumeUUID", nil];
}

static BOOL IdentityObservationIsUsable(NSDictionary *observation) {
	return observation && [[observation objectForKey:@"volumeUUID"] length] != 0;
}

static int RunIdentityRestartObservation(NSURL *directoryURL) {
	NSError *error = nil;
	NSDictionary *observation = FileIdentityObservation(
		[directoryURL URLByAppendingPathComponent:@"identity-current.bin"], &error);
	Report(IdentityObservationIsUsable(observation) ? @"PASS" : @"FAIL",
		@"AV-03-identity-restart", IdentityObservationIsUsable(observation) ?
		@"fresh process obtained optional identity fields and volume evidence without reading content" :
		[NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
	return failures == 0 ? 0 : 1;
}

static void TestFileIdentityLifecycle(NSURL *directoryURL, BOOL required,
	NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *sourceURL = [directoryURL URLByAppendingPathComponent:@"identity-source.bin"];
	NSURL *currentURL = [directoryURL URLByAppendingPathComponent:@"identity-current.bin"];
	RemoveContractItemIfPresent(sourceURL);
	RemoveContractItemIfPresent(currentURL);
	NSError *error = nil;
	NSData *first = UniquePatternData(64 * 1024, 0x91);
	NSData *second = UniquePatternData(64 * 1024 + 1, 0xA1);
	BOOL ready = CoordinatedWrite(sourceURL, first, &error);
	if (ready && [manager isUbiquitousItemAtURL:sourceURL])
		ready = WaitUntilUploaded(sourceURL, timeout);
	NSDictionary *created = ready ? FileIdentityObservation(sourceURL, &error) : nil;
	BOOL renamed = created && CoordinatedMove(sourceURL, currentURL, &error);
	NSDictionary *afterRename = renamed ? FileIdentityObservation(currentURL, &error) : nil;
	BOOL replaced = afterRename && CoordinatedSafeReplace(
		[[FreshURL(currentURL) absoluteURL] fileReferenceURL], second, &error);
	NSDictionary *afterReplacement = replaced ? FileIdentityObservation(currentURL, &error) : nil;
	BOOL usable = IdentityObservationIsUsable(created) &&
		IdentityObservationIsUsable(afterRename) && IdentityObservationIsUsable(afterReplacement);
	Report(usable ? @"PASS" : (required ? @"FAIL" : @"OBSERVE"),
		@"AV-03-identity-rename-replacement", usable ?
		@"optional document/file/generation fields and volume evidence were observed without requiring stability" :
		[NSString stringWithFormat:@"created=%d renamed=%d replaced=%d error=%@",
			created != nil, afterRename != nil, afterReplacement != nil, ErrorCode(error)]);

	if (usable && [manager isUbiquitousItemAtURL:currentURL]) {
		BOOL uploaded = WaitUntilUploaded(currentURL, timeout);
		BOOL evicted = uploaded && [manager evictUbiquitousItemAtURL:currentURL error:&error] &&
			WaitUntilNotDownloaded(currentURL, timeout);
		NSDictionary *whileEvicted = evicted ? FileIdentityObservation(currentURL, &error) : nil;
		BOOL stayedEvicted = whileEvicted &&
			IsDownloadStatus(currentURL, NSURLUbiquitousItemDownloadingStatusNotDownloaded);
		BOOL requested = stayedEvicted &&
			[manager startDownloadingUbiquitousItemAtURL:currentURL error:&error];
		BOOL materialized = requested && WaitUntilCurrent(currentURL, timeout);
		NSDictionary *afterMaterialization = materialized ?
			FileIdentityObservation(currentURL, &error) : nil;
		BOOL lifecycle = stayedEvicted && IdentityObservationIsUsable(whileEvicted) &&
			IdentityObservationIsUsable(afterMaterialization) &&
			[CoordinatedRead(currentURL, &error) isEqual:second];
		Report(lifecycle ? @"PASS" : @"OBSERVE",
			@"AV-03-identity-eviction", lifecycle ?
			@"identity metadata remained observable while evicted and after exact rematerialization" :
			[NSString stringWithFormat:@"evicted=%d stayed-evicted=%d materialized=%d error=%@",
				evicted, stayedEvicted, materialized, ErrorCode(error)]);
	}

	int restartStatus = usable ? RunChild([NSArray arrayWithObjects:
		@"identity-restart", [directoryURL path], nil]) : -1;
	Report(restartStatus == 0 ? @"PASS" : (required ? @"FAIL" : @"OBSERVE"),
		@"AV-03-identity-new-process", [NSString stringWithFormat:
			@"child-status=%d; identifier stability was recorded but not required", restartStatus]);
	RemoveContractItemIfPresent(currentURL);
}

static NSDictionary *CoordinatedPromisedMetadata(NSURL *url, NSArray *keys, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSDictionary *values = nil;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly
		error:&coordinationError byAccessor:^(NSURL *newURL) {
			values = [[newURL promisedItemResourceValuesForKeys:keys error:&accessError] retain];
		}];
	if (!values && outError)
		*outError = accessError ?: coordinationError;
	return [values autorelease];
}

static NSFileVersion *CoordinatedAddVersion(NSURL *url, NSURL *contentsURL, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSFileVersion *version = nil;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateWritingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		version = [[NSFileVersion addVersionOfItemAtURL:newURL withContentsOfURL:contentsURL
			options:0 error:&accessError] retain];
	}];
	if (!version && outError)
		*outError = accessError ?: coordinationError;
	return [version autorelease];
}

static NSFileVersion *CoordinatedCurrentVersion(NSURL *url, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSFileVersion *version = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		version = [[NSFileVersion currentVersionOfItemAtURL:newURL] retain];
	}];
	if (!version && outError)
		*outError = coordinationError ?: [NSError errorWithDomain:@"NVAPIContractTest" code:EAGAIN userInfo:nil];
	return [version autorelease];
}

static BOOL IsDownloadStatus(NSURL *url, NSURLUbiquitousItemDownloadingStatus status) {
	return [[ResourceValue(url, NSURLUbiquitousItemDownloadingStatusKey, NULL) description] isEqualToString:status];
}

static BOOL WaitUntilUploaded(NSURL *url, NSTimeInterval timeout) {
	return WaitFor(timeout, ^BOOL{
		NSError *error = ResourceValue(url, NSURLUbiquitousItemUploadingErrorKey, NULL);
		NSNumber *uploaded = ResourceValue(url, NSURLUbiquitousItemIsUploadedKey, NULL);
		NSNumber *uploading = ResourceValue(url, NSURLUbiquitousItemIsUploadingKey, NULL);
		return !error && [uploaded boolValue] && ![uploading boolValue];
	});
}

static BOOL WaitUntilCurrent(NSURL *url, NSTimeInterval timeout) {
	return WaitFor(timeout, ^BOOL{
		return IsDownloadStatus(url, NSURLUbiquitousItemDownloadingStatusCurrent);
	});
}

static BOOL WaitUntilNotDownloaded(NSURL *url, NSTimeInterval timeout) {
	return WaitFor(timeout, ^BOOL{
		return IsDownloadStatus(url, NSURLUbiquitousItemDownloadingStatusNotDownloaded);
	});
}

@interface NVVersionPresenter : NSObject <NSFilePresenter> {
	NSURL *_presentedURL;
	NSOperationQueue *_operationQueue;
	NSUInteger _generation;
}
- (id)initWithURL:(NSURL *)url;
- (NSUInteger)generation;
@end

@implementation NVVersionPresenter
- (id)initWithURL:(NSURL *)url {
	if ((self = [super init])) {
		_presentedURL = [url retain];
		_operationQueue = [[NSOperationQueue alloc] init];
		[_operationQueue setMaxConcurrentOperationCount:1];
		[_operationQueue setName:@"NV version contract presenter"];
	}
	return self;
}
- (void)dealloc {
	[_presentedURL release];
	[_operationQueue release];
	[super dealloc];
}
- (NSURL *)presentedItemURL { return _presentedURL; }
- (NSOperationQueue *)presentedItemOperationQueue { return _operationQueue; }
- (void)presentedItemDidChange { @synchronized (self) { _generation++; } }
- (void)presentedItemDidGainVersion:(NSFileVersion *)version { @synchronized (self) { _generation++; } }
- (void)presentedItemDidLoseVersion:(NSFileVersion *)version { @synchronized (self) { _generation++; } }
- (void)presentedItemDidResolveConflictVersion:(NSFileVersion *)version { @synchronized (self) { _generation++; } }
- (NSUInteger)generation { @synchronized (self) { return _generation; } }
@end

static NSSet *VersionIdentifiers(NSDictionary *snapshot) {
	if (!snapshot)
		return nil;
	NSMutableSet *identifiers = [NSMutableSet set];
	id current = [snapshot objectForKey:@"current"];
	if (current && current != [NSNull null] && [current persistentIdentifier])
		[identifiers addObject:[current persistentIdentifier]];
	for (NSString *key in [NSArray arrayWithObjects:@"other", @"unresolved", @"nonlocal", nil]) {
		for (NSFileVersion *version in [snapshot objectForKey:key]) {
			id identifier = [version persistentIdentifier];
			if (identifier)
				[identifiers addObject:identifier];
		}
	}
	return identifiers;
}

static NSDictionary *CopyLocalVersions(NSURL *url, NVVersionPresenter *presenter,
	BOOL registerPresenter, BOOL startNonlocalRequest,
	void (^nonlocalCompletion)(NSArray *, NSError *), NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:presenter] autorelease];
	__block NSFileVersion *current = nil;
	__block NSArray *other = nil;
	__block NSArray *unresolved = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		if (registerPresenter)
			[NSFileCoordinator addFilePresenter:presenter];
		current = [[NSFileVersion currentVersionOfItemAtURL:newURL] retain];
		other = [[NSFileVersion otherVersionsOfItemAtURL:newURL] retain];
		unresolved = [[NSFileVersion unresolvedConflictVersionsOfItemAtURL:newURL] retain];
		if (startNonlocalRequest)
			[NSFileVersion getNonlocalVersionsOfItemAtURL:newURL completionHandler:nonlocalCompletion];
	}];
	if (coordinationError) {
		if (outError)
			*outError = coordinationError;
		[current release];
		[other release];
		[unresolved release];
		return nil;
	}
	NSDictionary *snapshot = [NSDictionary dictionaryWithObjectsAndKeys:
		current ?: (id)[NSNull null], @"current",
		other ?: (id)[NSArray array], @"other",
		unresolved ?: (id)[NSArray array], @"unresolved", nil];
	[current release];
	[other release];
	[unresolved release];
	return snapshot;
}

static NSDictionary *CollectVersions(NSURL *url, NSTimeInterval timeout, NSError **outError) {
	NVVersionPresenter *presenter = [[[NVVersionPresenter alloc] initWithURL:url] autorelease];
	NSDictionary *result = nil;
	NSError *resultError = nil;
	for (NSUInteger attempt = 0; attempt < 3 && !result; attempt++) {
		__block NSArray *nonlocal = nil;
		__block NSError *nonlocalError = nil;
		__block BOOL callbackCompleted = NO;
		dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
		NSUInteger generation = [presenter generation];
		NSError *firstError = nil;
		NSDictionary *first = CopyLocalVersions(url, presenter, attempt == 0, YES, ^(NSArray *versions, NSError *error) {
			nonlocal = [versions retain];
			nonlocalError = [error retain];
			callbackCompleted = YES;
			dispatch_semaphore_signal(semaphore);
		}, &firstError);
		BOOL returned = first && WaitSemaphore(semaphore, timeout);
		NSError *secondError = nil;
		NSDictionary *second = returned && !nonlocalError ?
			CopyLocalVersions(url, presenter, NO, NO, nil, &secondError) : nil;
		BOOL stable = first && second && callbackCompleted && nonlocal && !nonlocalError &&
			[VersionIdentifiers(first) isEqual:VersionIdentifiers(second)] &&
			generation == [presenter generation];
		if (stable) {
			result = [[NSDictionary alloc] initWithObjectsAndKeys:
				[second objectForKey:@"current"], @"current",
				[second objectForKey:@"other"], @"other",
				[second objectForKey:@"unresolved"], @"unresolved",
				nonlocal, @"nonlocal", nil];
		} else if (!returned || firstError || secondError || nonlocalError) {
			resultError = [firstError ?: secondError ?: nonlocalError ?:
				[NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil] retain];
			[nonlocal release];
			[nonlocalError release];
			break;
		}
		[nonlocal release];
		[nonlocalError release];
	}
	if ([[NSFileCoordinator filePresenters] containsObject:presenter])
		[NSFileCoordinator removeFilePresenter:presenter];
	[[presenter presentedItemOperationQueue] waitUntilAllOperationsAreFinished];
	if (!result && !resultError)
		resultError = [[NSError errorWithDomain:@"NVAPIContractTest" code:EAGAIN userInfo:nil] retain];
	if (!result && outError)
		*outError = [[resultError retain] autorelease];
	[resultError release];
	return [result autorelease];
}

static NSArray *CopyVersionPayloads(NSDictionary *snapshot, NSURL *currentURL, NSError **outError) {
	if (!snapshot)
		return nil;
	NSMutableArray *payloads = [[NSMutableArray alloc] init];
	NSMutableSet *seen = [NSMutableSet set];
	id current = [snapshot objectForKey:@"current"];
	if (current && current != [NSNull null]) {
		id identifier = [current persistentIdentifier];
		NSData *data = CoordinatedRead(currentURL, outError);
		if (!data) {
			[payloads release];
			return nil;
		}
		[payloads addObject:data];
		if (identifier)
			[seen addObject:identifier];
	}
	for (NSString *key in [NSArray arrayWithObjects:@"other", @"unresolved", @"nonlocal", nil]) {
		for (NSFileVersion *version in [snapshot objectForKey:key]) {
			id identifier = [version persistentIdentifier];
			if (identifier && [seen containsObject:identifier])
				continue;
			NSData *data = CoordinatedRead([version URL], outError);
			if (!data) {
				[payloads release];
				return nil;
			}
			[payloads addObject:data];
			if (identifier)
				[seen addObject:identifier];
		}
	}
	return payloads;
}

static BOOL PayloadsContain(NSArray *payloads, NSData *first, NSData *second) {
	return [payloads containsObject:first] && [payloads containsObject:second];
}

@interface NVContractPresenter : NSObject <NSFilePresenter> {
	NSURL *_presentedURL;
	NSOperationQueue *_operationQueue;
	NSUInteger _appearanceCount;
	NSUInteger _changeCount;
	NSUInteger _moveCount;
	NSUInteger _deletionCount;
	NSUInteger _versionCount;
	NSUInteger _rootMoveCount;
	NSMutableArray *_eventLeafNames;
	NSMutableSet *_versionIdentifiers;
}
- (id)initWithURL:(NSURL *)url;
- (NSUInteger)eventCount;
- (NSUInteger)rootMoveCount;
- (NSURL *)currentURL;
- (NSArray *)eventLeafNames;
- (NSSet *)versionIdentifiers;
@end

@implementation NVContractPresenter
- (id)initWithURL:(NSURL *)url {
	if ((self = [super init])) {
		_presentedURL = [url retain];
		_operationQueue = [[NSOperationQueue alloc] init];
		[_operationQueue setMaxConcurrentOperationCount:1];
		[_operationQueue setName:@"NV iCloud API contract presenter"];
		_eventLeafNames = [[NSMutableArray alloc] init];
		_versionIdentifiers = [[NSMutableSet alloc] init];
	}
	return self;
}
- (void)dealloc {
	[_presentedURL release];
	[_operationQueue release];
	[_eventLeafNames release];
	[_versionIdentifiers release];
	[super dealloc];
}
- (NSURL *)presentedItemURL { @synchronized (self) { return [[_presentedURL retain] autorelease]; } }
- (NSOperationQueue *)presentedItemOperationQueue { return _operationQueue; }
- (NSSet *)observedPresentedItemUbiquityAttributes {
	return [NSSet setWithObjects:NSURLIsUbiquitousItemKey, NSURLUbiquitousItemDownloadingStatusKey,
		NSURLUbiquitousItemIsUploadedKey, NSURLUbiquitousItemIsUploadingKey,
		NSURLUbiquitousItemUploadingErrorKey, nil];
}
- (void)presentedItemDidChange { @synchronized (self) { _changeCount++; [_eventLeafNames addObject:[_presentedURL lastPathComponent]]; } }
- (void)presentedItemDidChangeUbiquityAttributes:(NSSet<NSURLResourceKey> *)attributes { @synchronized (self) {
	_changeCount++;
	[_eventLeafNames addObject:[_presentedURL lastPathComponent]];
} }
- (void)presentedSubitemDidAppearAtURL:(NSURL *)url { @synchronized (self) { _appearanceCount++; [_eventLeafNames addObject:[url lastPathComponent]]; } }
- (void)presentedSubitemDidChangeAtURL:(NSURL *)url { @synchronized (self) { _changeCount++; [_eventLeafNames addObject:[url lastPathComponent]]; } }
- (void)presentedSubitemAtURL:(NSURL *)oldURL didMoveToURL:(NSURL *)newURL { @synchronized (self) {
	_moveCount++;
	[_eventLeafNames addObject:[oldURL lastPathComponent]];
	[_eventLeafNames addObject:[newURL lastPathComponent]];
} }
- (void)accommodatePresentedSubitemDeletionAtURL:(NSURL *)url completionHandler:(void (^)(NSError *))completionHandler {
	@synchronized (self) { _deletionCount++; [_eventLeafNames addObject:[url lastPathComponent]]; }
	completionHandler(nil);
}
- (void)recordVersion:(NSFileVersion *)version atURL:(NSURL *)url {
	@synchronized (self) {
		_versionCount++;
		if (url)
			[_eventLeafNames addObject:[url lastPathComponent]];
		if ([version persistentIdentifier])
			[_versionIdentifiers addObject:[version persistentIdentifier]];
	}
}
- (void)presentedItemDidGainVersion:(NSFileVersion *)version { [self recordVersion:version atURL:_presentedURL]; }
- (void)presentedItemDidLoseVersion:(NSFileVersion *)version { [self recordVersion:version atURL:_presentedURL]; }
- (void)presentedItemDidResolveConflictVersion:(NSFileVersion *)version { [self recordVersion:version atURL:_presentedURL]; }
- (void)presentedSubitemAtURL:(NSURL *)url didGainVersion:(NSFileVersion *)version { [self recordVersion:version atURL:url]; }
- (void)presentedSubitemAtURL:(NSURL *)url didLoseVersion:(NSFileVersion *)version { [self recordVersion:version atURL:url]; }
- (void)presentedSubitemAtURL:(NSURL *)url didResolveConflictVersion:(NSFileVersion *)version { [self recordVersion:version atURL:url]; }
- (void)presentedItemDidMoveToURL:(NSURL *)newURL {
	@synchronized (self) {
		[_presentedURL release];
		_presentedURL = [newURL retain];
		_rootMoveCount++;
	}
}
- (NSUInteger)eventCount {
	@synchronized (self) { return _appearanceCount + _changeCount + _moveCount + _deletionCount + _versionCount; }
}
- (NSUInteger)rootMoveCount { @synchronized (self) { return _rootMoveCount; } }
- (NSURL *)currentURL { return [self presentedItemURL]; }
- (NSArray *)eventLeafNames { @synchronized (self) { return [[_eventLeafNames copy] autorelease]; } }
- (NSSet *)versionIdentifiers { @synchronized (self) { return [[_versionIdentifiers copy] autorelease]; } }
@end

static int ChildMutate(NSURL *directoryURL) {
	NSError *error = nil;
	NSURL *firstURL = [directoryURL URLByAppendingPathComponent:@"ipc-a.txt"];
	NSURL *secondURL = [directoryURL URLByAppendingPathComponent:@"ipc-b.txt"];
	if (!CoordinatedWrite(firstURL, [@"one" dataUsingEncoding:NSUTF8StringEncoding], &error))
		return 2;
	[NSThread sleepForTimeInterval:0.25];
	if (!CoordinatedWrite(firstURL, [@"two" dataUsingEncoding:NSUTF8StringEncoding], &error))
		return 3;
	[NSThread sleepForTimeInterval:0.25];
	if (!CoordinatedMove(firstURL, secondURL, &error))
		return 4;
	[NSThread sleepForTimeInterval:0.25];
	if (!CoordinatedDelete(secondURL, &error))
		return 5;
	return 0;
}

static int ChildRawMutate(NSURL *directoryURL) {
	NSError *error = nil;
	NSURL *firstURL = [directoryURL URLByAppendingPathComponent:@"raw-a.txt"];
	NSURL *secondURL = [directoryURL URLByAppendingPathComponent:@"raw-b.txt"];
	if (!RawWrite(firstURL, [@"one" dataUsingEncoding:NSUTF8StringEncoding], &error))
		return 2;
	[NSThread sleepForTimeInterval:0.25];
	if (!RawWrite(firstURL, [@"two" dataUsingEncoding:NSUTF8StringEncoding], &error))
		return 3;
	[NSThread sleepForTimeInterval:0.25];
	if (rename([firstURL fileSystemRepresentation], [secondURL fileSystemRepresentation]) < 0)
		return 4;
	return 0;
}

static int ChildMoveRoot(NSURL *sourceURL, NSURL *destinationURL) {
	NSError *error = nil;
	return CoordinatedMove(sourceURL, destinationURL, &error) ? 0 : 2;
}

static int ChildMoveRootMarked(NSURL *sourceURL, NSURL *destinationURL, NSURL *markerURL) {
	NSError *error = nil;
	NSData *marker = [@"ready" dataUsingEncoding:NSUTF8StringEncoding];
	if (!CoordinatedWrite(markerURL, marker, &error))
		return 2;
	return CoordinatedMove(sourceURL, destinationURL, &error) ? 0 : 3;
}

static int RunOSAScript(NSArray *statements, NSArray *arguments) {
	NSMutableArray *taskArguments = [NSMutableArray array];
	for (NSString *statement in statements) {
		[taskArguments addObject:@"-e"];
		[taskArguments addObject:statement];
	}
	[taskArguments addObjectsFromArray:arguments];
	NSTask *task = [[[NSTask alloc] init] autorelease];
	[task setExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/osascript"]];
	[task setArguments:taskArguments];
	NSFileHandle *nullDevice = [NSFileHandle fileHandleWithNullDevice];
	[task setStandardOutput:nullDevice];
	[task setStandardError:nullDevice];
	if (![task launchAndReturnError:NULL])
		return -1;
	if (!WaitFor(30.0, ^BOOL{ return ![task isRunning]; })) {
		[task terminate];
		if (!WaitFor(5.0, ^BOOL{ return ![task isRunning]; })) {
			kill([task processIdentifier], SIGKILL);
			WaitFor(5.0, ^BOOL{ return ![task isRunning]; });
		}
		return 124;
	}
	return [task terminationStatus];
}

static int FinderDuplicate(NSURL *sourceURL, NSURL *destinationDirectoryURL) {
	NSArray *statements = [NSArray arrayWithObjects:
		@"on run argv",
		@"set sourceFile to POSIX file (item 1 of argv)",
		@"set destinationFolder to POSIX file (item 2 of argv)",
		@"tell application \"Finder\" to duplicate sourceFile to destinationFolder with replacing",
		@"end run", nil];
	return RunOSAScript(statements, [NSArray arrayWithObjects:[sourceURL path],
		[destinationDirectoryURL path], nil]);
}

static int TextEditSave(NSURL *url, NSString *contents) {
	NSArray *statements = [NSArray arrayWithObjects:
		@"on run argv",
		@"set targetFile to POSIX file (item 1 of argv)",
		@"tell application \"TextEdit\"",
		@"set openedDocument to open targetFile",
		@"set text of openedDocument to item 2 of argv",
		@"save openedDocument",
		@"close openedDocument saving no",
		@"end tell",
		@"end run", nil];
	return RunOSAScript(statements, [NSArray arrayWithObjects:[url path], contents, nil]);
}

static NSTask *LaunchChild(NSArray *arguments) {
	NSTask *task = [[[NSTask alloc] init] autorelease];
	[task setExecutableURL:[NSURL fileURLWithPath:[[NSBundle mainBundle] executablePath]]];
	[task setArguments:arguments];
	NSError *error = nil;
	if (![task launchAndReturnError:&error])
		return nil;
	return task;
}

static int RunChild(NSArray *arguments) {
	NSTask *task = LaunchChild(arguments);
	if (!task)
		return -1;
	[task waitUntilExit];
	return [task terminationStatus];
}

static NSURL *OnlyReadyRemoteSession(NSURL *rootURL, NSError **outError) {
	NSURL *candidate = [rootURL URLByAppendingPathComponent:@"nv-api-contract-remote" isDirectory:YES];
	NSDictionary *sessionCatalog = CoordinatedCatalog(candidate, outError);
	return [sessionCatalog objectForKey:@"READY"] && ![sessionCatalog objectForKey:@"DONE"] ? candidate : nil;
}

static NSURL *XAttrSessionURL(NSURL *rootURL) {
	return [rootURL URLByAppendingPathComponent:@"nv-api-contract-xattr-v2" isDirectory:YES];
}

static NSArray *XAttrFileNames(void) {
	return [NSArray arrayWithObjects:@"eviction.txt", @"rename-source.txt", @"foundation.txt",
		@"finder.txt", @"textedit.txt", nil];
}

static NSData *XAttrPayload(NSUInteger index) {
	return [[NSString stringWithFormat:@"xattr-%lu\n", (unsigned long)index]
		dataUsingEncoding:NSUTF8StringEncoding];
}

static BOOL WaitUntilMaterializedWithPayload(NSURL *url, NSData *payload,
	NSTimeInterval timeout, NSError **outError) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSError *error = nil;
	if ([manager isUbiquitousItemAtURL:url] &&
		(![manager startDownloadingUbiquitousItemAtURL:url error:&error] ||
		 !WaitUntilCurrent(url, timeout))) {
		if (outError)
			*outError = error ?: [NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
		return NO;
	}
	NSData *current = CoordinatedRead(url, &error);
	if (![current isEqual:payload] && outError)
		*outError = error ?: [NSError errorWithDomain:@"NVAPIContractTest" code:EIO userInfo:nil];
	return [current isEqual:payload];
}

static int RunXAttrPeer(NSURL *rootURL, NSTimeInterval timeout) {
	NSURL *sessionURL = XAttrSessionURL(rootURL);
	if (!WaitForMarker(sessionURL, @"READY", timeout)) {
		Report(@"FAIL", @"AV-XATTR-peer", @"host READY marker did not arrive");
		return 1;
	}
	NSString *name = SyncableUUIDXAttrName();
	NSArray *fileNames = XAttrFileNames();
	BOOL visible = name != nil && WaitFor(timeout, ^BOOL{
		NSDictionary *catalog = CoordinatedCatalog(sessionURL, NULL);
		for (NSString *fileName in fileNames)
			if (![catalog objectForKey:fileName])
				return NO;
		return YES;
	});
	NSUInteger synced = 0;
	for (NSUInteger index = 0; visible && index < [fileNames count]; index++) {
		NSURL *url = [sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:index]];
		if (WaitForXAttr(url, name, ContractUUIDData(index),
			NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly, MIN(timeout, 120.0)))
			synced++;
	}
	Report(visible && synced == [fileNames count] ? @"PASS" : @"OBSERVE",
		@"AV-XATTR-cross-device", [NSString stringWithFormat:@"visible=%d syncable-uuids=%lu/%lu",
		visible, (unsigned long)synced, (unsigned long)[fileNames count]]);

	NSError *error = nil;
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *evictionURL = [sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:0]];
	BOOL evicted = IsDownloadStatus(evictionURL, NSURLUbiquitousItemDownloadingStatusNotDownloaded) ||
		([manager evictUbiquitousItemAtURL:evictionURL error:&error] &&
		 WaitUntilNotDownloaded(evictionURL, timeout));
	NSData *evictedUUID = evicted ? CoordinatedXAttrData(evictionURL, name,
		NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly, &error) : nil;
	BOOL stayedEvicted = evicted && IsDownloadStatus(evictionURL,
		NSURLUbiquitousItemDownloadingStatusNotDownloaded);
	Report(stayedEvicted && [evictedUUID isEqual:ContractUUIDData(0)] ? @"PASS" : @"OBSERVE",
		@"AV-XATTR-dataless", [NSString stringWithFormat:@"evicted=%d uuid-readable=%d remained-evicted=%d error=%@",
		evicted, [evictedUUID isEqual:ContractUUIDData(0)], stayedEvicted, ErrorCode(error)]);
	BOOL rematerialized = WaitUntilMaterializedWithPayload(evictionURL, XAttrPayload(0), timeout, &error);
	NSData *materializedUUID = rematerialized ? CoordinatedXAttrData(evictionURL, name, 0, &error) : nil;
	Report(rematerialized && [materializedUUID isEqual:ContractUUIDData(0)] ? @"PASS" : @"OBSERVE",
		@"AV-XATTR-rematerialization", [NSString stringWithFormat:@"body=%d uuid=%d error=%@",
		rematerialized, [materializedUUID isEqual:ContractUUIDData(0)], ErrorCode(error)]);

	error = nil;
	NSURL *renameURL = [sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:1]];
	NSURL *renamedURL = [sessionURL URLByAppendingPathComponent:@"renamed.txt"];
	BOOL renamed = CoordinatedMove(renameURL, renamedURL, &error);
	NSData *renamedUUID = renamed ? CoordinatedXAttrData(renamedURL, name, 0, &error) : nil;
	Report(renamed && [renamedUUID isEqual:ContractUUIDData(1)] ? @"PASS" : @"OBSERVE",
		@"AV-XATTR-rename", [NSString stringWithFormat:@"moved=%d uuid=%d error=%@",
		renamed, [renamedUUID isEqual:ContractUUIDData(1)], ErrorCode(error)]);

	error = nil;
	NSURL *foundationURL = [sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:2]];
	BOOL foundationReady = WaitUntilMaterializedWithPayload(foundationURL, XAttrPayload(2), timeout, &error);
	NSData *foundationPayload = [@"foundation-replaced\n" dataUsingEncoding:NSUTF8StringEncoding];
	BOOL foundationWrote = foundationReady && CoordinatedWrite(foundationURL, foundationPayload, &error);
	NSData *foundationUUID = foundationWrote ? CoordinatedXAttrData(foundationURL, name, 0, &error) : nil;
	Report(foundationWrote && [foundationUUID isEqual:ContractUUIDData(2)] ? @"PASS" : @"OBSERVE",
		@"AV-XATTR-foundation-safe-save", [NSString stringWithFormat:@"wrote=%d uuid=%d error=%@",
		foundationWrote, [foundationUUID isEqual:ContractUUIDData(2)], ErrorCode(error)]);

	error = nil;
	Report(@"READY", @"AV-XATTR-interactive",
		@"Finder and TextEdit may request user interaction for synthetic test documents");
	NSURL *finderURL = [sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:3]];
	BOOL finderReady = WaitUntilMaterializedWithPayload(finderURL, XAttrPayload(3), timeout, &error);
	NSURL *finderDirectory = [sessionURL URLByAppendingPathComponent:@"finder-copy" isDirectory:YES];
	BOOL finderDirectoryReady = finderReady && CoordinatedCreateDirectory(finderDirectory, &error);
	int finderStatus = finderDirectoryReady ? FinderDuplicate(finderURL, finderDirectory) : -1;
	NSURL *finderCopyURL = [finderDirectory URLByAppendingPathComponent:[finderURL lastPathComponent]];
	BOOL finderCopied = finderStatus == 0 && WaitFor(timeout, ^BOOL{
		return [[NSFileManager defaultManager] fileExistsAtPath:[finderCopyURL path]];
	});
	NSData *finderUUID = finderCopied ? CoordinatedXAttrData(finderCopyURL, name, 0, &error) : nil;
	Report(finderCopied && [finderUUID isEqual:ContractUUIDData(3)] ? @"PASS" : @"OBSERVE",
		@"AV-XATTR-finder-duplicate", [NSString stringWithFormat:@"automation-status=%d copied=%d uuid=%d error=%@",
		finderStatus, finderCopied, [finderUUID isEqual:ContractUUIDData(3)], ErrorCode(error)]);

	error = nil;
	NSURL *textEditURL = [sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:4]];
	BOOL textEditReady = WaitUntilMaterializedWithPayload(textEditURL, XAttrPayload(4), timeout, &error);
	NSString *textEditString = @"textedit-replaced\n";
	int textEditStatus = textEditReady ? TextEditSave(textEditURL, textEditString) : -1;
	NSData *textEditPayload = [textEditString dataUsingEncoding:NSUTF8StringEncoding];
	BOOL textEditWrote = textEditStatus == 0 && WaitFor(MIN(timeout, 60.0), ^BOOL{
		return [CoordinatedRead(textEditURL, NULL) isEqual:textEditPayload];
	});
	NSData *textEditUUID = textEditWrote ? CoordinatedXAttrData(textEditURL, name, 0, &error) : nil;
	Report(textEditWrote && [textEditUUID isEqual:ContractUUIDData(4)] ? @"PASS" : @"OBSERVE",
		@"AV-XATTR-textedit-safe-save", [NSString stringWithFormat:@"automation-status=%d wrote=%d uuid=%d error=%@",
		textEditStatus, textEditWrote, [textEditUUID isEqual:ContractUUIDData(4)], ErrorCode(error)]);

	BOOL uploaded = renamed && foundationWrote;
	for (NSURL *url in [NSArray arrayWithObjects:renamedURL, foundationURL, nil])
		if ([manager isUbiquitousItemAtURL:url])
			uploaded &= WaitUntilUploaded(url, timeout);
	if (finderCopied && [manager isUbiquitousItemAtURL:finderCopyURL])
		uploaded &= WaitUntilUploaded(finderCopyURL, timeout);
	if (textEditWrote && [manager isUbiquitousItemAtURL:textEditURL])
		uploaded &= WaitUntilUploaded(textEditURL, timeout);
	BOOL done = uploaded && WriteUploadedMarker(sessionURL, @"DONE", timeout, &error) &&
		WaitForMarker(sessionURL, @"ACK", timeout) &&
		WriteUploadedMarker(sessionURL, @"FINISHED", timeout, &error);
	Report(done ? @"PASS" : @"FAIL", @"AV-XATTR-peer-handshake",
		done ? @"peer mutations completed" : [NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
	return failures == 0 ? 0 : 1;
}

static int RunXAttrHost(NSURL *rootURL, NSTimeInterval timeout) {
	NSURL *sessionURL = XAttrSessionURL(rootURL);
	NSFileManager *manager = [NSFileManager defaultManager];
	if ([manager fileExistsAtPath:[sessionURL path]])
		CoordinatedDelete(sessionURL, NULL);
	NSError *error = nil;
	NSString *name = SyncableUUIDXAttrName();
	BOOL ready = name != nil && CoordinatedCreateDirectory(sessionURL, &error);
	NSArray *fileNames = XAttrFileNames();
	for (NSUInteger index = 0; ready && index < [fileNames count]; index++) {
		NSURL *url = [sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:index]];
		ready &= CoordinatedWriteWithUUID(url, XAttrPayload(index), ContractUUIDData(index), &error);
		if (ready && [manager isUbiquitousItemAtURL:url])
			ready &= WaitUntilUploaded(url, timeout);
	}
	ready &= WriteUploadedMarker(sessionURL, @"READY", timeout, &error);
	if (!ready) {
		ReportError(@"FAIL", @"AV-XATTR-host-setup", error);
		CoordinatedDelete(sessionURL, NULL);
		return 1;
	}
	Report(@"READY", @"AV-XATTR-host", @"run the xattr peer target on the second Mac");
	BOOL done = WaitForMarker(sessionURL, @"DONE", timeout);
	Report(done ? @"PASS" : @"FAIL", @"AV-XATTR-host-handshake",
		done ? @"peer completion marker arrived" : @"peer completion marker timed out");
	if (done) {
		NSArray *remoteURLs = [NSArray arrayWithObjects:
			[sessionURL URLByAppendingPathComponent:@"renamed.txt"],
			[sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:2]],
			[[sessionURL URLByAppendingPathComponent:@"finder-copy" isDirectory:YES]
				URLByAppendingPathComponent:[fileNames objectAtIndex:3]],
			[sessionURL URLByAppendingPathComponent:[fileNames objectAtIndex:4]], nil];
		NSUInteger expectedIndexes[] = { 1, 2, 3, 4 };
		NSArray *expectedPayloads = [NSArray arrayWithObjects:XAttrPayload(1),
			[@"foundation-replaced\n" dataUsingEncoding:NSUTF8StringEncoding], XAttrPayload(3),
			[@"textedit-replaced\n" dataUsingEncoding:NSUTF8StringEncoding], nil];
		NSArray *contracts = [NSArray arrayWithObjects:@"AV-XATTR-remote-rename",
			@"AV-XATTR-remote-safe-save", @"AV-XATTR-remote-finder-copy",
			@"AV-XATTR-remote-textedit", nil];
		for (NSUInteger index = 0; index < [remoteURLs count]; index++) {
			NSURL *url = [remoteURLs objectAtIndex:index];
			BOOL arrived = WaitFor(MIN(timeout, 60.0), ^BOOL{
				return [CoordinatedRead(url, NULL) isEqual:[expectedPayloads objectAtIndex:index]];
			});
			BOOL preserved = arrived && WaitForXAttr(url, name, ContractUUIDData(expectedIndexes[index]),
				NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly, MIN(timeout, 60.0));
			Report(preserved ? @"PASS" : @"OBSERVE", [contracts objectAtIndex:index],
				[NSString stringWithFormat:@"visible=%d uuid=%d", arrived, preserved]);
		}
	}
	BOOL acknowledged = done && WriteUploadedMarker(sessionURL, @"ACK", timeout, &error);
	BOOL finished = acknowledged && WaitForMarker(sessionURL, @"FINISHED", timeout);
	Report(finished ? @"PASS" : @"FAIL", @"AV-XATTR-host-finish",
		finished ? @"peer observed host verification" : @"peer did not finish");
	if (!CoordinatedDelete(sessionURL, &error))
		ReportError(@"FAIL", @"AV-XATTR-cleanup", error);
	else
		Report(@"PASS", @"AV-XATTR-cleanup", @"xattr test subtree removed");
	return failures == 0 ? 0 : 1;
}

static int CleanupXAttrSession(NSURL *rootURL) {
	NSError *error = nil;
	NSURL *sessionURL = XAttrSessionURL(rootURL);
	if (CoordinatedDelete(sessionURL, &error) ||
		([[error domain] isEqualToString:NSCocoaErrorDomain] && [error code] == NSFileNoSuchFileError)) {
		Report(@"PASS", @"AV-XATTR-cleanup", @"xattr rendezvous absent or removed");
		return 0;
	}
	ReportError(@"FAIL", @"AV-XATTR-cleanup", error);
	return 1;
}

static int RunRemotePeer(NSURL *rootURL, NSTimeInterval timeout) {
	__block NSError *error = nil;
	__block NSURL *sessionURL = nil;
	BOOL found = WaitFor(timeout, ^BOOL{
		sessionURL = [OnlyReadyRemoteSession(rootURL, NULL) retain];
		return sessionURL != nil;
	});
	if (!found) {
		error = [NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
		ReportError(@"FAIL", @"REMOTE-SETUP", error);
		return 1;
	}

	NSURL *readyURL = [sessionURL URLByAppendingPathComponent:@"READY"];
	if ([[NSFileManager defaultManager] isUbiquitousItemAtURL:readyURL] &&
		(![[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:readyURL error:&error] ||
		 !WaitUntilCurrent(readyURL, timeout))) {
		ReportError(@"FAIL", @"REMOTE-SETUP", error);
		[sessionURL release];
		return 1;
	}
	if (!CoordinatedRead(readyURL, &error)) {
		ReportError(@"FAIL", @"REMOTE-SETUP", error);
		[sessionURL release];
		return 1;
	}

	NSURL *editURL = [sessionURL URLByAppendingPathComponent:@"remote-edit.txt"];
	NSURL *renameURL = [sessionURL URLByAppendingPathComponent:@"remote-rename.txt"];
	NSURL *renamedURL = [sessionURL URLByAppendingPathComponent:@"remote-renamed.txt"];
	NSURL *deleteURL = [sessionURL URLByAppendingPathComponent:@"remote-delete.txt"];
	NSURL *doneURL = [sessionURL URLByAppendingPathComponent:@"DONE"];
	BOOL mutated = CoordinatedWrite(editURL, [@"peer" dataUsingEncoding:NSUTF8StringEncoding], &error) &&
		CoordinatedMove(renameURL, renamedURL, &error) && CoordinatedDelete(deleteURL, &error);
	BOOL ubiquitous = [[NSFileManager defaultManager] isUbiquitousItemAtURL:editURL];
	if (mutated && ubiquitous)
		mutated = WaitUntilUploaded(editURL, timeout) && WaitUntilUploaded(renamedURL, timeout);
	if (mutated)
		mutated = CoordinatedWrite(doneURL, [@"done" dataUsingEncoding:NSUTF8StringEncoding], &error);
	if (mutated && ubiquitous)
		mutated = WaitUntilUploaded(doneURL, timeout);
	if (mutated)
		mutated = WaitFor(timeout, ^BOOL{
			return [[CoordinatedCatalog(sessionURL, NULL) allKeys] containsObject:@"ACK"];
		});
	if (mutated)
		mutated = CoordinatedWrite([sessionURL URLByAppendingPathComponent:@"FINISHED"],
			[@"finished" dataUsingEncoding:NSUTF8StringEncoding], &error);
	if (!mutated && !error)
		error = [NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
	Report(mutated ? @"PASS" : @"FAIL", @"REMOTE-PEER", mutated ?
		@"remote mutation set uploaded" : [NSString stringWithFormat:@"remote mutation failed error=%@", ErrorCode(error)]);
	[sessionURL release];
	return mutated ? 0 : 1;
}

static BOOL RemoteMutationIsExactlyVisible(NSURL *sessionURL) {
	NSDictionary *catalog = CoordinatedCatalog(sessionURL, NULL);
	BOOL namespaceMatches = [catalog objectForKey:@"remote-renamed.txt"] &&
		![catalog objectForKey:@"remote-rename.txt"] && ![catalog objectForKey:@"remote-delete.txt"];
	if (!namespaceMatches)
		return NO;
	NSData *editData = CoordinatedRead([sessionURL URLByAppendingPathComponent:@"remote-edit.txt"], NULL);
	return [editData isEqual:[@"peer" dataUsingEncoding:NSUTF8StringEncoding]];
}

static BOOL HistoricalPayloadAtURL(NSURL *url, NSData *expected, NSTimeInterval timeout, NSError **outError) {
	NSDictionary *versions = CollectVersions(url, timeout, outError);
	NSArray *payloads = CopyVersionPayloads(versions, url, outError);
	BOOL found = [payloads containsObject:expected];
	[payloads release];
	return found;
}

static int RunHistoryRestartInspect(NSURL *sessionURL, NSTimeInterval timeout) {
	NSError *renameError = nil;
	NSError *deleteError = nil;
	BOOL renameHistory = HistoricalPayloadAtURL(
		[sessionURL URLByAppendingPathComponent:@"remote-rename.txt"],
		[@"rename" dataUsingEncoding:NSUTF8StringEncoding], timeout, &renameError);
	BOOL deleteHistory = HistoricalPayloadAtURL(
		[sessionURL URLByAppendingPathComponent:@"remote-delete.txt"],
		[@"delete" dataUsingEncoding:NSUTF8StringEncoding], timeout, &deleteError);
	NSData *renamedData = CoordinatedRead([sessionURL URLByAppendingPathComponent:@"remote-renamed.txt"], NULL);
	Report(renameHistory ? @"PASS" : @"OBSERVE", @"AV-06-restart-rename",
		renameHistory ? @"retained pre-rename URL redisclosed the renamed state after process restart" :
		[NSString stringWithFormat:@"retained pre-rename URL disclosed no readable history error=%@", ErrorCode(renameError)]);
	Report(deleteHistory ? @"PASS" : @"OBSERVE", @"AV-06-restart-delete",
		deleteHistory ? @"retained pre-delete URL redisclosed deleted state after process restart" :
		[NSString stringWithFormat:@"retained pre-delete URL disclosed no readable history error=%@", ErrorCode(deleteError)]);
	Report([renamedData isEqual:[@"rename" dataUsingEncoding:NSUTF8StringEncoding]] ? @"PASS" : @"FAIL",
		@"AV-06-restart-current", @"renamed current URL remained readable after process restart");
	return failures == 0 ? 0 : 1;
}

static int RunRemoteHost(NSURL *rootURL, NSTimeInterval timeout) {
	NSString *runID = [[NSUUID UUID] UUIDString];
	NSURL *sessionURL = [rootURL URLByAppendingPathComponent:@"nv-api-contract-remote" isDirectory:YES];
	NSError *error = nil;
	if (!CoordinatedCreateDirectory(sessionURL, &error)) {
		ReportError(@"FAIL", @"REMOTE-SETUP", error);
		return 1;
	}
	NVContractPresenter *presenter = [[[NVContractPresenter alloc] initWithURL:sessionURL] autorelease];
	[NSFileCoordinator addFilePresenter:presenter];
	NSDictionary *files = [NSDictionary dictionaryWithObjectsAndKeys:
		[@"base" dataUsingEncoding:NSUTF8StringEncoding], @"remote-edit.txt",
		[@"rename" dataUsingEncoding:NSUTF8StringEncoding], @"remote-rename.txt",
		[@"delete" dataUsingEncoding:NSUTF8StringEncoding], @"remote-delete.txt",
		[runID dataUsingEncoding:NSUTF8StringEncoding], @"READY", nil];
	BOOL ready = YES;
	for (NSString *name in files) {
		NSURL *url = [sessionURL URLByAppendingPathComponent:name];
		ready &= CoordinatedWrite(url, [files objectForKey:name], &error);
	}
	if (ready && [[NSFileManager defaultManager] isUbiquitousItemAtURL:sessionURL]) {
		for (NSString *name in files)
			ready &= WaitUntilUploaded([sessionURL URLByAppendingPathComponent:name], timeout);
	}
	if (!ready) {
		ReportError(@"FAIL", @"REMOTE-SETUP", error);
		[NSFileCoordinator removeFilePresenter:presenter];
		CoordinatedDelete(sessionURL, NULL);
		return 1;
	}
	Report(@"READY", @"REMOTE-HOST", @"run the remote-peer target once on the second Mac");

	NSUInteger eventsBefore = [presenter eventCount];
	BOOL doneVisible = WaitFor(timeout, ^BOOL{
		return [[CoordinatedCatalog(sessionURL, NULL) allKeys] containsObject:@"DONE"];
	});
	BOOL markerArrivedBeforeState = doneVisible && !RemoteMutationIsExactlyVisible(sessionURL);
	BOOL stateVisible = doneVisible && !markerArrivedBeforeState;
	if (doneVisible && !stateVisible)
		stateVisible = WaitFor(timeout, ^BOOL{ return RemoteMutationIsExactlyVisible(sessionURL); });
	if (markerArrivedBeforeState)
		Report(@"OBSERVE", @"AV-07-order", @"completion marker preceded the exact cross-file state");
	BOOL gotCallback = WaitFor(10.0, ^BOOL{ return [presenter eventCount] > eventsBefore; });
	if (!stateVisible)
		error = [NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
	NSDictionary *versions = stateVisible ? CollectVersions([sessionURL URLByAppendingPathComponent:@"remote-edit.txt"], timeout, &error) : nil;
	Report(stateVisible ? @"PASS" : @"FAIL", @"AV-02/03-remote",
		stateVisible ? @"remote edit/rename/delete became exactly observable" :
		[NSString stringWithFormat:@"remote state incomplete error=%@", ErrorCode(error)]);
	Report(gotCallback ? @"PASS" : @"FAIL", @"AV-07-remote",
		gotCallback ? @"remote mutation produced presenter activity" : @"remote mutation produced no presenter activity");
	Report(versions ? @"PASS" : @"FAIL", @"AV-05-remote", versions ?
		@"remote candidate version enumeration completed" : [NSString stringWithFormat:@"remote versions incomplete error=%@", ErrorCode(error)]);
	BOOL acknowledged = CoordinatedWrite([sessionURL URLByAppendingPathComponent:@"ACK"],
		[@"ack" dataUsingEncoding:NSUTF8StringEncoding], &error);
	BOOL peerFinished = acknowledged && WaitFor(timeout, ^BOOL{
		return [[CoordinatedCatalog(sessionURL, NULL) allKeys] containsObject:@"FINISHED"];
	});
	Report(peerFinished ? @"PASS" : @"FAIL", @"REMOTE-HANDSHAKE",
		peerFinished ? @"peer observed host verification" : @"peer did not acknowledge host verification");
	NSArray *eventLeafNames = [presenter eventLeafNames];
	BOOL callbackURLs = [eventLeafNames containsObject:@"remote-rename.txt"] &&
		[eventLeafNames containsObject:@"remote-renamed.txt"] &&
		[eventLeafNames containsObject:@"remote-delete.txt"];
	Report(callbackURLs ? @"PASS" : @"OBSERVE", @"AV-06-callback-URLs",
		callbackURLs ? @"presenter supplied rename and deletion candidate URLs" :
		[NSString stringWithFormat:@"observed-leaves=%@", eventLeafNames]);
	[NSFileCoordinator removeFilePresenter:presenter];
	[[presenter presentedItemOperationQueue] waitUntilAllOperationsAreFinished];
	int restartStatus = RunChild([NSArray arrayWithObjects:@"history-restart", [sessionURL path], nil]);
	Report(restartStatus == 0 ? @"PASS" : @"FAIL", @"AV-06-process-restart",
		restartStatus == 0 ? @"fresh process completed retained-URL history inspection" :
		[NSString stringWithFormat:@"child-status=%d", restartStatus]);
	if (!CoordinatedDelete(sessionURL, &error))
		ReportError(@"FAIL", @"CLEANUP", error);
	else
		Report(@"PASS", @"CLEANUP", @"remote test subtree removed");
	return failures == 0 ? 0 : 1;
}

static const NSUInteger NVConflictFileCount = 8;

static NSURL *ConflictSessionURL(NSURL *rootURL) {
	return [rootURL URLByAppendingPathComponent:@"nv-api-contract-conflict" isDirectory:YES];
}

static NSURL *ConflictFileURL(NSURL *sessionURL, NSUInteger index) {
	return [sessionURL URLByAppendingPathComponent:[NSString stringWithFormat:@"fork-%02lu.txt", (unsigned long)index]];
}

static NSData *ConflictPayload(NSString *side, NSUInteger index) {
	return [[NSString stringWithFormat:@"%@-%02lu\n", side, (unsigned long)index] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *ArchiveVersionIdentifier(id identifier, NSError **outError) {
	NSData *archive = nil;
	@try {
		archive = [NSKeyedArchiver archivedDataWithRootObject:identifier
			requiringSecureCoding:NO error:outError];
	} @catch (NSException *exception) {
		if (outError)
			*outError = [NSError errorWithDomain:@"NVAPIContractTest" code:EINVAL userInfo:nil];
	}
	return archive;
}

static BOOL WriteIdentifierExport(NSArray *entries, NSURL *outputURL) {
	NSDictionary *plist = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithUnsignedInteger:1], @"format", entries, @"entries", nil];
	return [plist writeToURL:outputURL atomically:YES];
}

static int RunConflictPrepare(NSURL *rootURL, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	if ([manager fileExistsAtPath:[sessionURL path]])
		CoordinatedDelete(sessionURL, NULL);
	NSError *error = nil;
	if (!CoordinatedCreateDirectory(sessionURL, &error)) {
		ReportError(@"FAIL", @"AV-05-conflict-setup", error);
		return 1;
	}
	NSString *xattrName = SyncableUUIDXAttrName();
	BOOL ready = YES;
	BOOL xattrsReady = xattrName != nil;
	for (NSUInteger index = 0; index < NVConflictFileCount; index++) {
		NSURL *url = ConflictFileURL(sessionURL, index);
		ready &= CoordinatedWrite(url, ConflictPayload(@"base", index), &error);
		if (ready)
			xattrsReady &= CoordinatedSetXAttrData(url, xattrName, ContractUUIDData(index), &error);
	}
	if (ready && [manager isUbiquitousItemAtURL:sessionURL]) {
		for (NSUInteger index = 0; index < NVConflictFileCount; index++)
			ready &= WaitUntilUploaded(ConflictFileURL(sessionURL, index), timeout);
	}
	Report(ready ? @"PASS" : @"FAIL", @"AV-05-conflict-setup",
		ready ? @"synchronized conflict bases are ready" : [NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
	Report(xattrsReady ? @"PASS" : @"OBSERVE", @"AV-XATTR-conflict-setup",
		xattrsReady ? @"every conflict base has a syncable UUID" :
		[NSString stringWithFormat:@"syncable UUID setup incomplete error=%@", ErrorCode(error)]);
	return ready ? 0 : 1;
}

static int RunConflictMaterialize(NSURL *rootURL, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	BOOL complete = WaitFor(timeout, ^BOOL{
		NSDictionary *catalog = CoordinatedCatalog(sessionURL, NULL);
		return [catalog count] >= NVConflictFileCount;
	});
	NSError *error = nil;
	NSString *xattrName = SyncableUUIDXAttrName();
	NSUInteger xattrs = 0;
	for (NSUInteger index = 0; complete && index < NVConflictFileCount; index++) {
		NSURL *url = ConflictFileURL(sessionURL, index);
		if ([manager isUbiquitousItemAtURL:url])
			complete &= [manager startDownloadingUbiquitousItemAtURL:url error:&error] && WaitUntilCurrent(url, timeout);
		complete &= [CoordinatedRead(url, &error) isEqual:ConflictPayload(@"base", index)];
		if ([CoordinatedXAttrData(url, xattrName, 0, NULL) isEqual:ContractUUIDData(index)])
			xattrs++;
	}
	Report(complete ? @"PASS" : @"FAIL", @"AV-05-conflict-materialize",
		complete ? @"every conflict base is current and byte-identical" : [NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
	Report(xattrs == NVConflictFileCount ? @"PASS" : @"OBSERVE", @"AV-XATTR-conflict-materialize",
		[NSString stringWithFormat:@"syncable-uuids=%lu/%lu", (unsigned long)xattrs,
			(unsigned long)NVConflictFileCount]);
	return complete ? 0 : 1;
}

static int RunConflictWrite(NSURL *rootURL, NSString *side, NSTimeInterval startTime,
	NSTimeInterval timeout, NSURL *identifierOutputURL) {
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:startTime];
	while ([startDate timeIntervalSinceNow] > 0.0)
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(0.02, [startDate timeIntervalSinceNow])]];
	NSError *error = nil;
	NSString *xattrName = SyncableUUIDXAttrName();
	BOOL wrote = YES;
	NSUInteger xattrs = 0;
	NSMutableArray *identifierEntries = [NSMutableArray array];
	BOOL reverseOrder = [side isEqualToString:@"peer"];
	for (NSUInteger iteration = 0; iteration < NVConflictFileCount; iteration++) {
		NSUInteger index = reverseOrder ? NVConflictFileCount - iteration - 1 : iteration;
		NSURL *url = ConflictFileURL(sessionURL, index);
		NSFileManagerItemReplacementOptions options = index < NVConflictFileCount / 2 ? 0 :
			NSFileManagerItemReplacementUsingNewMetadataOnly;
		NSData *payload = ConflictPayload(side, index);
		BOOL wroteOne = CoordinatedSafeReplaceWithUUID(url, payload,
			ContractUUIDData(index), options, &error) != nil;
		wrote &= wroteOne;
		if (wroteOne && identifierOutputURL && [CoordinatedRead(url, NULL) isEqual:payload]) {
			NSFileVersion *version = CoordinatedCurrentVersion(url, &error);
			NSData *archive = ArchiveVersionIdentifier([version persistentIdentifier], &error);
			if (archive)
				[identifierEntries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
					[NSNumber numberWithUnsignedInteger:index], @"fileIndex", side, @"side",
					archive, @"identifierArchive", nil]];
		}
		if ([CoordinatedXAttrData(url, xattrName, 0, NULL) isEqual:ContractUUIDData(index)])
			xattrs++;
		[NSThread sleepForTimeInterval:0.1];
	}
	if (identifierOutputURL) {
		BOOL exported = [identifierEntries count] == NVConflictFileCount &&
			WriteIdentifierExport(identifierEntries, identifierOutputURL);
		Report(exported ? @"PASS" : @"FAIL", @"AV-05-source-current-id-export",
			[NSString stringWithFormat:@"side=%@ entries=%lu/%lu", side,
				(unsigned long)[identifierEntries count], (unsigned long)NVConflictFileCount]);
		wrote &= exported;
	}
	BOOL uploaded = wrote;
	if (uploaded && [[NSFileManager defaultManager] isUbiquitousItemAtURL:sessionURL]) {
		for (NSUInteger index = 0; index < NVConflictFileCount; index++)
			uploaded &= WaitUntilUploaded(ConflictFileURL(sessionURL, index), timeout);
	}
	Report(uploaded ? @"PASS" : @"FAIL", @"AV-05-conflict-write",
		uploaded ? [NSString stringWithFormat:@"%@ fork uploaded", side] :
		[NSString stringWithFormat:@"%@ fork failed error=%@", side, ErrorCode(error)]);
	Report(xattrs == NVConflictFileCount ? @"PASS" : @"OBSERVE", @"AV-XATTR-conflict-safe-save",
		[NSString stringWithFormat:@"side=%@ staged-before-install syncable-uuids=%lu/%lu", side,
			(unsigned long)xattrs, (unsigned long)NVConflictFileCount]);
	return uploaded ? 0 : 1;
}

static int RunConflictEditDeleteWrite(NSURL *rootURL, NSString *operation,
	NSTimeInterval startTime) {
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:startTime];
	while ([startDate timeIntervalSinceNow] > 0.0)
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:
			MIN(0.02, [startDate timeIntervalSinceNow])]];
	BOOL edit = [operation isEqualToString:@"edit"];
	BOOL remove = [operation isEqualToString:@"delete"];
	NSError *error = nil;
	BOOL complete = edit || remove;
	for (NSUInteger index = 0; complete && index < NVConflictFileCount; index++) {
		NSURL *url = ConflictFileURL(sessionURL, index);
		complete = edit ? CoordinatedSafeReplace(url,
			ConflictPayload(@"edited", index), &error) != nil : CoordinatedDelete(url, &error);
		[NSThread sleepForTimeInterval:0.1];
	}
	Report(complete ? @"PASS" : @"FAIL", @"AV-05-edit-delete-write",
		complete ? [NSString stringWithFormat:@"%@ branch was admitted for every file", operation] :
		[NSString stringWithFormat:@"operation=%@ error=%@", operation, ErrorCode(error)]);
	return complete ? 0 : 1;
}

static int RunConflictEditDeleteInspect(NSURL *rootURL, NSTimeInterval timeout) {
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	__block NSUInteger currentOrUnresolved = 0;
	BOOL allCurrentOrUnresolved = WaitFor(timeout, ^BOOL{
		currentOrUnresolved = 0;
		for (NSUInteger index = 0; index < NVConflictFileCount; index++) {
			NSURL *url = ConflictFileURL(sessionURL, index);
			NSData *payload = ConflictPayload(@"edited", index);
			NSData *current = CoordinatedRead(url, NULL);
			NSArray *unresolved = current ? CoordinatedUnresolvedVersions(url, NULL) :
				[NSFileVersion unresolvedConflictVersionsOfItemAtURL:url];
			if ([current isEqual:payload] || VersionsContainPayload(unresolved, payload))
				currentOrUnresolved++;
		}
		return currentOrUnresolved == NVConflictFileCount;
	});
	NSUInteger other = 0, nonlocal = 0, anyVersionAPI = 0;
	NSUInteger completeNonlocalQueries = 0, failedNonlocalQueries = 0, timedOutNonlocalQueries = 0;
	NSString *lastNonlocalError = @"none";
	for (NSUInteger index = 0; index < NVConflictFileCount; index++) {
		NSURL *url = ConflictFileURL(sessionURL, index);
		NSData *payload = ConflictPayload(@"edited", index);
		NSArray *otherVersions = [NSFileVersion otherVersionsOfItemAtURL:url];
		if (VersionsContainPayload(otherVersions, payload))
			other++;

		__block NSArray *nonlocalVersions = nil;
		__block NSError *nonlocalError = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		[NSFileVersion getNonlocalVersionsOfItemAtURL:url completionHandler:
			^(NSArray *versions, NSError *error) {
				nonlocalVersions = [versions retain];
				nonlocalError = [error retain];
				dispatch_semaphore_signal(done);
			}];
		BOOL nonlocalReturned = WaitSemaphore(done, MIN(timeout, 60.0));
		if (nonlocalReturned && !nonlocalError) {
			completeNonlocalQueries++;
			if (VersionsContainPayload(nonlocalVersions, payload))
				nonlocal++;
		} else if (nonlocalReturned) {
			failedNonlocalQueries++;
			lastNonlocalError = ErrorCode(nonlocalError);
		} else
			timedOutNonlocalQueries++;
		if (VersionsContainPayload(otherVersions, payload) ||
			VersionsContainPayload(nonlocalVersions, payload))
			anyVersionAPI++;
		[nonlocalVersions release];
		[nonlocalError release];
	}
	Report(allCurrentOrUnresolved ? @"PASS" : @"OBSERVE", @"AV-05-edit-delete-current-visible",
		[NSString stringWithFormat:@"edited-current-or-unresolved=%lu/%lu",
			(unsigned long)currentOrUnresolved, (unsigned long)NVConflictFileCount]);
	Report(@"OBSERVE", @"AV-05-edit-delete-historical-visibility",
		[NSString stringWithFormat:
			@"edited-other=%lu nonlocal=%lu any-historical-API=%lu/%lu nonlocal-complete/failed/timed-out=%lu/%lu/%lu last-error=%@; absence is not evidence of provider-side data destruction",
			(unsigned long)other, (unsigned long)nonlocal, (unsigned long)anyVersionAPI,
			(unsigned long)NVConflictFileCount, (unsigned long)completeNonlocalQueries,
			(unsigned long)failedNonlocalQueries, (unsigned long)timedOutNonlocalQueries,
			lastNonlocalError]);
	return 0;
}

static BOOL SnapshotPayloadHasXAttr(NSDictionary *snapshot, NSURL *currentURL,
	NSData *payload, NSString *xattrName, NSData *xattrValue) {
	id current = [snapshot objectForKey:@"current"];
	if (current && current != [NSNull null] &&
		[CoordinatedRead(currentURL, NULL) isEqual:payload] &&
		[CoordinatedXAttrData(currentURL, xattrName, 0, NULL) isEqual:xattrValue])
		return YES;
	NSMutableSet *seen = [NSMutableSet set];
	for (NSString *key in [NSArray arrayWithObjects:@"other", @"unresolved", @"nonlocal", nil]) {
		for (NSFileVersion *version in [snapshot objectForKey:key]) {
			id identifier = [version persistentIdentifier];
			if (identifier && [seen containsObject:identifier])
				continue;
			NSURL *url = [version URL];
			if ([CoordinatedRead(url, NULL) isEqual:payload] &&
				[CoordinatedXAttrData(url, xattrName, 0, NULL) isEqual:xattrValue])
				return YES;
			if (identifier)
				[seen addObject:identifier];
		}
	}
	return NO;
}

static NSSet *IdentifiersForVersionKind(NSDictionary *snapshot, NSString *key) {
	NSMutableSet *identifiers = [NSMutableSet set];
	for (NSFileVersion *version in [snapshot objectForKey:key]) {
		if ([version persistentIdentifier])
			[identifiers addObject:[version persistentIdentifier]];
	}
	return identifiers;
}

static int RunConflictInspect(NSURL *rootURL, NSTimeInterval timeout, BOOL required) {
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	NSUInteger conflicts = 0;
	NSUInteger otherVersions = 0;
	NSUInteger unresolvedVersions = 0;
	NSUInteger nonlocalVersions = 0;
	NSUInteger migratedVersions = 0;
	NSUInteger completeSnapshots = 0;
	NSUInteger xattrConflicts = 0;
	NSUInteger hostXattrPayloads = 0;
	NSUInteger peerXattrPayloads = 0;
	NSUInteger currentXattrs = 0;
	NSUInteger hostCurrent = 0;
	NSUInteger peerCurrent = 0;
	NSString *xattrName = SyncableUUIDXAttrName();
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	do {
		conflicts = otherVersions = unresolvedVersions = nonlocalVersions = migratedVersions = completeSnapshots = 0;
		xattrConflicts = hostXattrPayloads = peerXattrPayloads = currentXattrs = 0;
		hostCurrent = peerCurrent = 0;
		for (NSUInteger index = 0; index < NVConflictFileCount; index++) {
			NSURL *url = ConflictFileURL(sessionURL, index);
			NSError *error = nil;
			NSDictionary *snapshot = CollectVersions(url, MIN(60.0, timeout), &error);
			if (!snapshot)
				continue;
			completeSnapshots++;
			if ([CoordinatedXAttrData(url, xattrName, 0, NULL) isEqual:ContractUUIDData(index)])
				currentXattrs++;
			otherVersions += [[snapshot objectForKey:@"other"] count];
			unresolvedVersions += [[snapshot objectForKey:@"unresolved"] count];
			NSSet *initialNonlocal = IdentifiersForVersionKind(snapshot, @"nonlocal");
			nonlocalVersions += [initialNonlocal count];
			NSArray *payloads = CopyVersionPayloads(snapshot, url, &error);
			if (PayloadsContain(payloads, ConflictPayload(@"host", index), ConflictPayload(@"peer", index))) {
				conflicts++;
				NSData *currentPayload = CoordinatedRead(url, NULL);
				if ([currentPayload isEqual:ConflictPayload(@"host", index)])
					hostCurrent++;
				else if ([currentPayload isEqual:ConflictPayload(@"peer", index)])
					peerCurrent++;
				BOOL hostXattr = SnapshotPayloadHasXAttr(snapshot, url, ConflictPayload(@"host", index),
					xattrName, ContractUUIDData(index));
				BOOL peerXattr = SnapshotPayloadHasXAttr(snapshot, url, ConflictPayload(@"peer", index),
					xattrName, ContractUUIDData(index));
				if (hostXattr)
					hostXattrPayloads++;
				if (peerXattr)
					peerXattrPayloads++;
				if (hostXattr && peerXattr)
					xattrConflicts++;
			}
			[payloads release];
			if ([initialNonlocal count]) {
				NSDictionary *after = CollectVersions(url, MIN(60.0, timeout), NULL);
				NSMutableSet *localAfter = [NSMutableSet setWithSet:IdentifiersForVersionKind(after, @"other")];
				[localAfter unionSet:IdentifiersForVersionKind(after, @"unresolved")];
				for (id identifier in initialNonlocal)
					if ([localAfter containsObject:identifier])
						migratedVersions++;
			}
		}
		if ((required ? conflicts < NVConflictFileCount : !conflicts) &&
			[deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
	} while ((required ? conflicts < NVConflictFileCount : !conflicts) &&
		[deadline timeIntervalSinceNow] > 0.0);
	Report(completeSnapshots == NVConflictFileCount ? @"PASS" : @"FAIL", @"AV-05-conflict-snapshots",
		[NSString stringWithFormat:@"complete=%lu/%lu", (unsigned long)completeSnapshots, (unsigned long)NVConflictFileCount]);
	BOOL conflictCoverage = required ? conflicts == NVConflictFileCount : conflicts != 0;
	Report(conflictCoverage ? @"PASS" : (required ? @"FAIL" : @"OBSERVE"), @"AV-05-real-conflict",
		conflicts ? [NSString stringWithFormat:@"preserved both payloads for %lu/%lu simultaneous forks",
			(unsigned long)conflicts, (unsigned long)NVConflictFileCount] :
		@"provider converged simultaneous writes without exposing both payloads as versions");
	Report(@"OBSERVE", @"AV-05-current-outcome", [NSString stringWithFormat:
		@"host-current=%lu peer-current=%lu; provider settlement order is observational",
		(unsigned long)hostCurrent, (unsigned long)peerCurrent]);
	Report(otherVersions || unresolvedVersions ? @"PASS" : @"OBSERVE", @"AV-05-version-kinds",
		[NSString stringWithFormat:@"other=%lu unresolved=%lu", (unsigned long)otherVersions,
			(unsigned long)unresolvedVersions]);
	Report(nonlocalVersions ? @"PASS" : @"OBSERVE", @"AV-05-nonlocal",
		nonlocalVersions ? [NSString stringWithFormat:@"observed %lu nonlocal versions; %lu retained identity after materialization",
			(unsigned long)nonlocalVersions, (unsigned long)migratedVersions] : @"no nonlocal version was exposed during the observation window");
	Report(conflicts && xattrConflicts == conflicts ? @"PASS" : @"OBSERVE",
		@"AV-XATTR-conflict-versions", [NSString stringWithFormat:
			@"both-payloads=%lu current=%lu host-body=%lu peer-body=%lu both-uuid-bearing=%lu",
			(unsigned long)conflicts, (unsigned long)currentXattrs,
			(unsigned long)hostXattrPayloads, (unsigned long)peerXattrPayloads,
			(unsigned long)xattrConflicts]);
	return failures == 0 ? 0 : 1;
}

static NSArray *UniqueSnapshotVersions(NSDictionary *snapshot) {
	NSMutableArray *versions = [NSMutableArray array];
	NSMutableSet *identifiers = [NSMutableSet set];
	id current = [snapshot objectForKey:@"current"];
	if (current && current != [NSNull null]) {
		[versions addObject:current];
		if ([current persistentIdentifier])
			[identifiers addObject:[current persistentIdentifier]];
	}
	for (NSString *key in [NSArray arrayWithObjects:@"other", @"unresolved", @"nonlocal", nil]) {
		for (NSFileVersion *version in [snapshot objectForKey:key]) {
			id identifier = [version persistentIdentifier];
			if (identifier && [identifiers containsObject:identifier])
				continue;
			[versions addObject:version];
			if (identifier)
				[identifiers addObject:identifier];
		}
	}
	return versions;
}

static NSData *SnapshotVersionPayload(NSDictionary *snapshot, NSURL *currentURL,
	NSFileVersion *version, NSError **outError) {
	id current = [snapshot objectForKey:@"current"];
	return current && current != [NSNull null] && [version isEqual:current] ?
		CoordinatedRead(currentURL, outError) : CoordinatedRead([version URL], outError);
}

static NSFileVersion *CoordinatedVersionForIdentifier(NSURL *url, id identifier,
	NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSFileVersion *version = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
		version = [[NSFileVersion versionOfItemAtURL:newURL
			forPersistentIdentifier:identifier] retain];
	}];
	if (!version && outError)
		*outError = coordinationError ?: [NSError errorWithDomain:@"NVAPIContractTest"
			code:ENOENT userInfo:nil];
	return [version autorelease];
}

static int RunConflictExportIdentifiers(NSURL *rootURL, NSURL *outputURL,
	NSTimeInterval timeout) {
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	NSMutableArray *entries = [NSMutableArray array];
	NSError *error = nil;
	for (NSUInteger index = 0; index < NVConflictFileCount; index++) {
		NSURL *url = ConflictFileURL(sessionURL, index);
		NSDictionary *snapshot = CollectVersions(url, timeout, &error);
		for (NSFileVersion *version in UniqueSnapshotVersions(snapshot)) {
			NSData *payload = SnapshotVersionPayload(snapshot, url, version, &error);
			NSString *side = [payload isEqual:ConflictPayload(@"host", index)] ? @"host" :
				([payload isEqual:ConflictPayload(@"peer", index)] ? @"peer" : nil);
			id identifier = [version persistentIdentifier];
			if (!side || !identifier)
				continue;
			NSData *archive = ArchiveVersionIdentifier(identifier, &error);
			if (archive)
				[entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
					[NSNumber numberWithUnsignedInteger:index], @"fileIndex", side, @"side",
					archive, @"identifierArchive", nil]];
		}
	}
	BOOL wrote = [entries count] == NVConflictFileCount * 2 &&
		WriteIdentifierExport(entries, outputURL);
	Report(wrote ? @"PASS" : @"FAIL", @"AV-05-persistent-id-export",
		[NSString stringWithFormat:@"entries=%lu/%lu error=%@", (unsigned long)[entries count],
			(unsigned long)(NVConflictFileCount * 2), ErrorCode(error)]);
	return wrote ? 0 : 1;
}

static int RunConflictCompareIdentifiers(NSURL *rootURL, NSURL *inputURL,
	NSTimeInterval timeout) {
	NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:inputURL];
	NSArray *entries = [plist objectForKey:@"entries"];
	if (![[plist objectForKey:@"format"] isEqual:[NSNumber numberWithUnsignedInteger:1]] ||
		![entries isKindOfClass:[NSArray class]]) {
		Report(@"FAIL", @"AV-05-persistent-id-portability", @"invalid comparison input");
		return 1;
	}
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	NSMutableDictionary *snapshots = [NSMutableDictionary dictionary];
	NSUInteger decoded = 0, equal = 0, lookedUp = 0;
	NSUInteger currentEntries = 0, currentDecoded = 0, currentEqual = 0, currentLookedUp = 0;
	NSUInteger historicalEntries = 0, historicalDecoded = 0, historicalEqual = 0, historicalLookedUp = 0;
	for (NSDictionary *entry in entries) {
		NSNumber *fileIndex = [entry objectForKey:@"fileIndex"];
		NSString *side = [entry objectForKey:@"side"];
		NSData *archive = [entry objectForKey:@"identifierArchive"];
		if (![fileIndex isKindOfClass:[NSNumber class]] || [fileIndex unsignedIntegerValue] >= NVConflictFileCount ||
			!([side isEqual:@"host"] || [side isEqual:@"peer"]) ||
			![archive isKindOfClass:[NSData class]])
			continue;
		NSUInteger index = [fileIndex unsignedIntegerValue];
		NSURL *url = ConflictFileURL(sessionURL, index);
		NSDictionary *snapshot = [snapshots objectForKey:fileIndex];
		if (!snapshot) {
			snapshot = CollectVersions(url, timeout, NULL);
			if (snapshot)
				[snapshots setObject:snapshot forKey:fileIndex];
		}
		NSFileVersion *localVersion = nil;
		NSData *expectedPayload = ConflictPayload(side, index);
		for (NSFileVersion *version in UniqueSnapshotVersions(snapshot))
			if ([SnapshotVersionPayload(snapshot, url, version, NULL) isEqual:expectedPayload]) {
				localVersion = version;
				break;
			}
		id current = [snapshot objectForKey:@"current"];
		BOOL isCurrent = localVersion && current != [NSNull null] && [localVersion isEqual:current];
		if (isCurrent)
			currentEntries++;
		else
			historicalEntries++;
		id foreignIdentifier = nil;
		@try {
			NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc]
				initForReadingFromData:archive error:NULL] autorelease];
			[unarchiver setRequiresSecureCoding:NO];
			foreignIdentifier = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
			[unarchiver finishDecoding];
		} @catch (NSException *exception) {
			foreignIdentifier = nil;
		}
		if (!foreignIdentifier)
			continue;
		decoded++;
		if (isCurrent)
			currentDecoded++;
		else
			historicalDecoded++;
		id localIdentifier = [localVersion persistentIdentifier];
		if (localIdentifier && [localIdentifier isEqual:foreignIdentifier]) {
			equal++;
			if (isCurrent)
				currentEqual++;
			else
				historicalEqual++;
		}
		NSFileVersion *found = CoordinatedVersionForIdentifier(url, foreignIdentifier, NULL);
		if (found && [SnapshotVersionPayload(snapshot, url, found, NULL) isEqual:expectedPayload]) {
			lookedUp++;
			if (isCurrent)
				currentLookedUp++;
			else
				historicalLookedUp++;
		}
	}
	Report(currentEntries && currentDecoded == currentEntries && currentEqual == currentEntries &&
		currentLookedUp == currentEntries ? @"PASS" : @"OBSERVE",
		@"AV-05-current-id-semantic-roundtrip", [NSString stringWithFormat:
			@"entries=%lu decoded=%lu equal=%lu lookup=%lu", (unsigned long)currentEntries,
			(unsigned long)currentDecoded, (unsigned long)currentEqual,
			(unsigned long)currentLookedUp]);
	Report(historicalEntries && historicalDecoded == historicalEntries && historicalEqual == historicalEntries &&
		historicalLookedUp == historicalEntries ? @"PASS" : @"OBSERVE",
		@"AV-05-historical-id-semantic-roundtrip", [NSString stringWithFormat:
			@"entries=%lu decoded=%lu equal=%lu lookup=%lu totals=%lu/%lu/%lu",
			(unsigned long)historicalEntries, (unsigned long)historicalDecoded,
			(unsigned long)historicalEqual, (unsigned long)historicalLookedUp,
			(unsigned long)decoded, (unsigned long)equal, (unsigned long)lookedUp]);
	return failures == 0 ? 0 : 1;
}

static NSArray *PayloadsForVersions(NSArray *versions, NSError **outError) {
	NSMutableArray *payloads = [NSMutableArray arrayWithCapacity:[versions count]];
	for (NSFileVersion *version in versions) {
		NSData *payload = CoordinatedRead([version URL], outError);
		if (!payload)
			return nil;
		[payloads addObject:payload];
	}
	return payloads;
}

static BOOL VersionsContainPayload(NSArray *versions, NSData *payload) {
	for (NSFileVersion *version in versions) {
		NSData *candidate = CoordinatedRead([version URL], NULL);
		if ([candidate isEqual:payload])
			return YES;
	}
	return NO;
}

static BOOL VersionsContainAnyPayload(NSArray *versions, NSArray *payloads) {
	for (NSData *payload in payloads)
		if (VersionsContainPayload(versions, payload))
			return YES;
	return NO;
}

static int RunConflictDisposition(NSURL *rootURL, NSTimeInterval timeout, BOOL required) {
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	__block NSURL *itemURL = nil;
	__block NSArray *captured = nil;
	__block NSArray *capturedPayloads = nil;
	__block NSError *error = nil;
	BOOL disclosed = WaitFor(timeout, ^BOOL{
		for (NSUInteger index = 0; index < NVConflictFileCount; index++) {
			NSURL *url = ConflictFileURL(sessionURL, index);
			NSNumber *conflict = ResourceValue(url,
				NSURLUbiquitousItemHasUnresolvedConflictsKey, NULL);
			NSArray *versions = CoordinatedUnresolvedVersions(url, &error);
			if ([conflict boolValue] && !versions)
				return YES;
			NSArray *payloads = PayloadsForVersions(versions, &error);
			if ([versions count] && [payloads count] == [versions count]) {
				itemURL = [url retain];
				captured = [versions retain];
				capturedPayloads = [payloads retain];
				return YES;
			}
		}
		return NO;
	});
	if (!disclosed || !captured) {
		Report(disclosed || required ? @"FAIL" : @"OBSERVE", @"AV-05-disclosure",
			disclosed ? [NSString stringWithFormat:@"positive conflict status produced ambiguous disclosure error=%@",
				ErrorCode(error)] : @"provider exposed no unresolved member during the observation window");
		[itemURL release];
		[captured release];
		[capturedPayloads release];
		return failures == 0 ? 0 : 1;
	}
	Report(@"PASS", @"AV-05-disclosure",
		[NSString stringWithFormat:@"captured=%lu", (unsigned long)[captured count]]);

	NSFileVersion *selected = [captured objectAtIndex:0];
	NSData *selectedPayload = [capturedPayloads objectAtIndex:0];
	NSData *newCurrent = UniquePatternData(257, 0xD7);
	BOOL changed = CoordinatedWrite(itemURL, newCurrent, &error);
	NSData *retainedPayload = changed ? CoordinatedRead([selected URL], &error) : nil;
	NSArray *beforeResolution = changed ? CoordinatedUnresolvedVersions(itemURL, &error) : nil;
	BOOL immutable = changed && [retainedPayload isEqual:selectedPayload] &&
		VersionsContainPayload(beforeResolution, selectedPayload);
	Report(immutable ? @"PASS" : @"FAIL", @"AV-05-immutable-member",
		immutable ? @"captured member remained exact after the current file changed" :
		[NSString stringWithFormat:@"changed=%d disclosed=%d error=%@", changed,
			VersionsContainPayload(beforeResolution, selectedPayload), ErrorCode(error)]);

	BOOL setterReturned = immutable && CoordinatedResolveVersion(itemURL, selected, &error);
	BOOL selectedDisappeared = setterReturned && WaitFor(timeout, ^BOOL{
		NSArray *fresh = CoordinatedUnresolvedVersions(itemURL, NULL);
		return fresh && !VersionsContainPayload(fresh, selectedPayload);
	});
	NSArray *afterOne = selectedDisappeared ? CoordinatedUnresolvedVersions(itemURL, &error) : nil;
	BOOL currentUnchanged = [CoordinatedRead(itemURL, &error) isEqual:newCurrent];
	Report(selectedDisappeared && currentUnchanged ? @"PASS" : @"FAIL", @"AV-05-one-member-resolution",
		selectedDisappeared && currentUnchanged ?
		[NSString stringWithFormat:@"remaining=%lu current-unchanged=1", (unsigned long)[afterOne count]] :
		[NSString stringWithFormat:@"setter=%d disappeared=%d current-unchanged=%d error=%@",
			setterReturned, selectedDisappeared, currentUnchanged, ErrorCode(error)]);

	BOOL repeatReturned = selectedDisappeared && CoordinatedResolveVersion(itemURL, selected, &error);
	NSArray *afterRepeat = repeatReturned ? CoordinatedUnresolvedVersions(itemURL, &error) : nil;
	BOOL repeatHarmless = repeatReturned && afterRepeat && [afterRepeat count] == [afterOne count] &&
		[CoordinatedRead(itemURL, NULL) isEqual:newCurrent];
	Report(repeatHarmless ? @"PASS" : @"FAIL", @"AV-05-repeat-resolution",
		repeatHarmless ? @"repeating resolution left current bytes and the fresh unresolved count unchanged" :
		[NSString stringWithFormat:@"repeat=%d before=%lu after=%lu error=%@", repeatReturned,
			(unsigned long)[afterOne count], (unsigned long)[afterRepeat count], ErrorCode(error)]);

	BOOL resolvedCaptured = repeatHarmless;
	for (NSUInteger index = 1; resolvedCaptured && index < [captured count]; index++)
		resolvedCaptured = CoordinatedResolveVersion(itemURL, [captured objectAtIndex:index], &error);
	NSArray *final = resolvedCaptured ? CoordinatedUnresolvedVersions(itemURL, &error) : nil;
	BOOL capturedAbsent = final && !VersionsContainAnyPayload(final, capturedPayloads) &&
		[CoordinatedRead(itemURL, NULL) isEqual:newCurrent];
	Report(capturedAbsent ? @"PASS" : @"FAIL", @"AV-05-snapshot-resolution",
		capturedAbsent ? [NSString stringWithFormat:@"fresh-remaining=%lu", (unsigned long)[final count]] :
		[NSString stringWithFormat:@"resolved=%d fresh=%d error=%@", resolvedCaptured,
			final != nil, ErrorCode(error)]);

	[itemURL release];
	[captured release];
	[capturedPayloads release];
	return failures == 0 ? 0 : 1;
}

static int CleanupConflictSession(NSURL *rootURL) {
	NSError *error = nil;
	NSURL *sessionURL = ConflictSessionURL(rootURL);
	if (CoordinatedDelete(sessionURL, &error) ||
		([[error domain] isEqualToString:NSCocoaErrorDomain] && [error code] == NSFileNoSuchFileError)) {
		Report(@"PASS", @"CLEANUP", @"conflict test subtree absent or removed");
		return 0;
	}
	ReportError(@"FAIL", @"CLEANUP", error);
	return 1;
}

static NSUInteger ManifestItemCount(void) {
	NSInteger configured = [[[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_ICLOUD_API_TEST_MANIFEST_COUNT"] integerValue];
	return configured >= 3 ? (NSUInteger)configured : 1000;
}

static NSURL *ManifestSessionURL(NSURL *rootURL) {
	return [rootURL URLByAppendingPathComponent:@"nv-api-contract-manifest" isDirectory:YES];
}

static NSString *ManifestItemName(NSUInteger index) {
	return [NSString stringWithFormat:@"item-%05lu.txt", (unsigned long)index];
}

static NSURL *ManifestItemURL(NSURL *sessionURL, NSUInteger index) {
	return [sessionURL URLByAppendingPathComponent:ManifestItemName(index)];
}

static NSData *ManifestPayload(NSUInteger index, NSString *side) {
	return [[NSString stringWithFormat:@"%@-%05lu\n", side, (unsigned long)index]
		dataUsingEncoding:NSUTF8StringEncoding];
}

static BOOL WaitUntilManifestUploaded(NSURL *sessionURL, NSUInteger count,
	NSTimeInterval timeout) {
	if (![[NSFileManager defaultManager] isUbiquitousItemAtURL:sessionURL])
		return YES;
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	for (NSUInteger index = 0; index < count; index++) {
		NSTimeInterval remaining = [deadline timeIntervalSinceNow];
		if (remaining <= 0.0 || !WaitUntilUploaded(ManifestItemURL(sessionURL, index), remaining))
			return NO;
	}
	return YES;
}

static BOOL CatalogHasInitialManifest(NSDictionary *catalog, NSUInteger count,
	NSUInteger markerCount) {
	if ([catalog count] != count + markerCount)
		return NO;
	for (NSUInteger index = 0; index < count; index++)
		if (![catalog objectForKey:ManifestItemName(index)])
			return NO;
	return [catalog objectForKey:@"READY"] &&
		(markerCount < 2 || [catalog objectForKey:@"PEER_READY"]);
}

static BOOL CatalogHasMutatedManifest(NSDictionary *catalog, NSUInteger count) {
	if ([catalog count] != count + 5 || [catalog objectForKey:ManifestItemName(0)] ||
		[catalog objectForKey:ManifestItemName(1)])
		return NO;
	for (NSUInteger index = 2; index < count; index++)
		if (![catalog objectForKey:ManifestItemName(index)])
			return NO;
	return [catalog objectForKey:@"item-renamed.txt"] &&
		[catalog objectForKey:@"item-new.txt"] && [catalog objectForKey:@"READY"] &&
		[catalog objectForKey:@"PEER_READY"] && [catalog objectForKey:@"GO"] &&
		[catalog objectForKey:@"REMOTE_COMMITTED"] && [catalog objectForKey:@"DONE"];
}

static int RunManifestPeer(NSURL *rootURL, NSTimeInterval timeout) {
	NSURL *sessionURL = ManifestSessionURL(rootURL);
	NSUInteger count = ManifestItemCount();
	if (!WaitForMarker(sessionURL, @"READY", timeout)) {
		Report(@"FAIL", @"AV-03-manifest-peer", @"host READY marker did not arrive");
		return 1;
	}
	NSError *error = nil;
	NSDictionary *initial = CoordinatedCatalog(sessionURL, &error);
	BOOL initialExact = CatalogHasInitialManifest(initial, count, 1);
	Report(initialExact ? @"PASS" : @"FAIL", @"AV-03-manifest-peer-initial",
		[NSString stringWithFormat:@"expected=%lu observed=%lu error=%@",
			(unsigned long)(count + 1), (unsigned long)[initial count], ErrorCode(error)]);

	NSFileManager *manager = [NSFileManager defaultManager];
	NSUInteger evicted = 0;
	for (NSUInteger index = 0; initialExact && index < MIN(count, (NSUInteger)16); index++) {
		NSURL *url = ManifestItemURL(sessionURL, index);
		if (IsDownloadStatus(url, NSURLUbiquitousItemDownloadingStatusNotDownloaded) ||
			([manager evictUbiquitousItemAtURL:url error:NULL] && WaitUntilNotDownloaded(url, timeout)))
			evicted++;
	}
	NSDictionary *afterEviction = initialExact ? CoordinatedCatalog(sessionURL, &error) : nil;
	NSUInteger stillEvicted = 0;
	for (NSUInteger index = 0; index < MIN(count, (NSUInteger)16); index++)
		if (IsDownloadStatus(ManifestItemURL(sessionURL, index),
			NSURLUbiquitousItemDownloadingStatusNotDownloaded))
			stillEvicted++;
	BOOL placeholdersStayedEvicted = evicted && stillEvicted == evicted &&
		CatalogHasInitialManifest(afterEviction, count, 1);
	Report(placeholdersStayedEvicted ? @"PASS" : @"FAIL", @"AV-03-manifest-placeholders",
		[NSString stringWithFormat:@"evicted=%lu still-evicted=%lu catalog=%lu error=%@",
			(unsigned long)evicted, (unsigned long)stillEvicted,
			(unsigned long)[afterEviction count], ErrorCode(error)]);

	BOOL ready = placeholdersStayedEvicted &&
		WriteUploadedMarker(sessionURL, @"PEER_READY", timeout, &error);
	if (!ready || !WaitForMarker(sessionURL, @"GO", timeout)) {
		Report(@"FAIL", @"AV-03-manifest-peer", [NSString stringWithFormat:
			@"peer readiness or GO failed error=%@", ErrorCode(error)]);
		return 1;
	}

	NSURL *editURL = ManifestItemURL(sessionURL, 2);
	BOOL mutated = CoordinatedWrite(editURL, ManifestPayload(2, @"peer"), &error) &&
		(![manager isUbiquitousItemAtURL:editURL] || WaitUntilUploaded(editURL, timeout)) &&
		WriteUploadedMarker(sessionURL, @"REMOTE_COMMITTED", timeout, &error) &&
		CoordinatedDelete(ManifestItemURL(sessionURL, 0), &error) &&
		CoordinatedMove(ManifestItemURL(sessionURL, 1),
			[sessionURL URLByAppendingPathComponent:@"item-renamed.txt"], &error) &&
		CoordinatedWrite([sessionURL URLByAppendingPathComponent:@"item-new.txt"],
			ManifestPayload(count, @"peer"), &error);
	if (mutated && [manager isUbiquitousItemAtURL:sessionURL])
		mutated = WaitUntilUploaded([sessionURL URLByAppendingPathComponent:@"item-renamed.txt"], timeout) &&
			WaitUntilUploaded([sessionURL URLByAppendingPathComponent:@"item-new.txt"], timeout);
	mutated = mutated && WriteUploadedMarker(sessionURL, @"DONE", timeout, &error);
	if (mutated)
		mutated = WaitForMarker(sessionURL, @"ACK", timeout);
	if (mutated)
		mutated = WriteUploadedMarker(sessionURL, @"FINISHED", timeout, &error);
	Report(mutated ? @"PASS" : @"FAIL", @"AV-03-manifest-peer-mutation",
		mutated ? @"peer mutation set and handshake completed" :
		[NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
	return mutated ? 0 : 1;
}

static int RunManifestHost(NSURL *rootURL, NSTimeInterval timeout) {
	NSURL *sessionURL = ManifestSessionURL(rootURL);
	NSFileManager *manager = [NSFileManager defaultManager];
	if ([manager fileExistsAtPath:[sessionURL path]])
		CoordinatedDelete(sessionURL, NULL);
	NSError *error = nil;
	NSUInteger count = ManifestItemCount();
	BOOL ready = CoordinatedCreateDirectory(sessionURL, &error);
	for (NSUInteger index = 0; ready && index < count; index++)
		ready = CoordinatedWrite(ManifestItemURL(sessionURL, index),
			ManifestPayload(index, @"base"), &error);
	ready = ready && WaitUntilManifestUploaded(sessionURL, count, timeout) &&
		WriteUploadedMarker(sessionURL, @"READY", timeout, &error);
	if (!ready) {
		Report(@"FAIL", @"AV-03-manifest-host-setup", [NSString stringWithFormat:
			@"count=%lu error=%@", (unsigned long)count, ErrorCode(error)]);
		return 1;
	}
	Report(@"READY", @"AV-03-manifest-host",
		[NSString stringWithFormat:@"count=%lu run manifest-peer on the second Mac",
			(unsigned long)count]);

	NVContractPresenter *presenter = [[[NVContractPresenter alloc] initWithURL:sessionURL] autorelease];
	[NSFileCoordinator addFilePresenter:presenter];
	BOOL peerReady = WaitForMarker(sessionURL, @"PEER_READY", timeout);
	NSDictionary *first = peerReady ? CoordinatedCatalog(sessionURL, &error) : nil;
	NSDictionary *second = peerReady ? CoordinatedCatalog(sessionURL, &error) : nil;
	BOOL stableInitial = peerReady && [first isEqual:second] &&
		CatalogHasInitialManifest(second, count, 2);
	Report(stableInitial ? @"PASS" : @"FAIL", @"AV-03-manifest-host-initial",
		[NSString stringWithFormat:@"stable=%d expected=%lu observed=%lu error=%@",
			[first isEqual:second], (unsigned long)(count + 2),
			(unsigned long)[second count], ErrorCode(error)]);

	NSURL *editURL = ManifestItemURL(sessionURL, 2);
	BOOL initiallyCurrent = IsDownloadStatus(editURL,
		NSURLUbiquitousItemDownloadingStatusCurrent);
	NSUInteger eventsBefore = [presenter eventCount];
	BOOL go = stableInitial && WriteUploadedMarker(sessionURL, @"GO", timeout, &error);
	BOOL remoteMarker = go && WaitForMarker(sessionURL, @"REMOTE_COMMITTED", timeout);
	NSData *atRemoteMarker = remoteMarker ? CoordinatedRead(editURL, &error) : nil;
	BOOL staleCurrent = remoteMarker && initiallyCurrent &&
		IsDownloadStatus(editURL, NSURLUbiquitousItemDownloadingStatusCurrent) &&
		[atRemoteMarker isEqual:ManifestPayload(2, @"base")];
	Report(staleCurrent ? @"PASS" : @"OBSERVE", @"AV-01-device-current",
		staleCurrent ? @"item still reported Current after the peer had uploaded a newer version" :
		[NSString stringWithFormat:@"initial-current=%d remote-marker=%d at-marker-current=%d remote-already-visible=%d error=%@",
			initiallyCurrent, remoteMarker, IsDownloadStatus(editURL,
				NSURLUbiquitousItemDownloadingStatusCurrent),
			[atRemoteMarker isEqual:ManifestPayload(2, @"peer")], ErrorCode(error)]);

	BOOL done = remoteMarker && WaitForMarker(sessionURL, @"DONE", timeout);
	BOOL exact = done && WaitFor(timeout, ^BOOL{
		NSDictionary *catalog = CoordinatedCatalog(sessionURL, NULL);
		return CatalogHasMutatedManifest(catalog, count) &&
			[CoordinatedRead(editURL, NULL) isEqual:ManifestPayload(2, @"peer")];
	});
	first = exact ? CoordinatedCatalog(sessionURL, &error) : nil;
	second = exact ? CoordinatedCatalog(sessionURL, &error) : nil;
	BOOL stableFinal = exact && [first isEqual:second] && CatalogHasMutatedManifest(second, count);
	Report(stableFinal ? @"PASS" : @"FAIL", @"AV-03-manifest-host-final",
		[NSString stringWithFormat:@"exact=%d stable=%d observed=%lu error=%@", exact,
			[first isEqual:second], (unsigned long)[second count], ErrorCode(error)]);
	BOOL callback = WaitFor(15.0, ^BOOL{ return [presenter eventCount] > eventsBefore; });
	Report(callback ? @"PASS" : @"FAIL", @"AV-07-manifest-liveness",
		callback ? @"remote manifest mutation produced presenter activity" :
		@"remote manifest mutation became visible without presenter activity");

	BOOL finished = stableFinal && WriteUploadedMarker(sessionURL, @"ACK", timeout, &error) &&
		WaitForMarker(sessionURL, @"FINISHED", timeout);
	[NSFileCoordinator removeFilePresenter:presenter];
	[[presenter presentedItemOperationQueue] waitUntilAllOperationsAreFinished];
	BOOL cleaned = finished && CoordinatedDelete(sessionURL, &error);
	Report(cleaned ? @"PASS" : @"FAIL", @"AV-03-manifest-cleanup",
		cleaned ? @"manifest test subtree removed" :
		[NSString stringWithFormat:@"finished=%d error=%@", finished, ErrorCode(error)]);
	return failures == 0 ? 0 : 1;
}

static int CleanupManifestSession(NSURL *rootURL) {
	NSError *error = nil;
	NSURL *sessionURL = ManifestSessionURL(rootURL);
	if (CoordinatedDelete(sessionURL, &error) ||
		([[error domain] isEqualToString:NSCocoaErrorDomain] && [error code] == NSFileNoSuchFileError)) {
		Report(@"PASS", @"CLEANUP", @"manifest test subtree absent or removed");
		return 0;
	}
	ReportError(@"FAIL", @"CLEANUP", error);
	return 1;
}

static NSURL *SyncConflictSessionURL(NSURL *rootURL) {
	return [rootURL URLByAppendingPathComponent:@"nv-api-contract-sync-conflict" isDirectory:YES];
}

static BOOL WaitForMarker(NSURL *sessionURL, NSString *name, NSTimeInterval timeout) {
	return WaitFor(timeout, ^BOOL{
		return [[CoordinatedCatalog(sessionURL, NULL) allKeys] containsObject:name];
	});
}

static BOOL WriteUploadedMarker(NSURL *sessionURL, NSString *name, NSTimeInterval timeout, NSError **outError) {
	NSURL *url = [sessionURL URLByAppendingPathComponent:name];
	BOOL wrote = CoordinatedWrite(url, [[name stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding], outError);
	return wrote && (![[NSFileManager defaultManager] isUbiquitousItemAtURL:url] || WaitUntilUploaded(url, timeout));
}

static int RunSyncConflictPeer(NSURL *rootURL, NSTimeInterval timeout) {
	NSURL *sessionURL = SyncConflictSessionURL(rootURL);
	if (!WaitForMarker(sessionURL, @"READY", timeout)) {
		Report(@"FAIL", @"AV-10-conflict-peer", @"host READY marker did not arrive");
		return 1;
	}
	NSURL *itemURL = [sessionURL URLByAppendingPathComponent:@"checkpoint.bin"];
	NSError *error = nil;
	NSFileManager *manager = [NSFileManager defaultManager];
	BOOL baseReady = ![manager isUbiquitousItemAtURL:itemURL] ||
		([manager startDownloadingUbiquitousItemAtURL:itemURL error:&error] && WaitUntilCurrent(itemURL, timeout));
	baseReady &= [CoordinatedRead(itemURL, &error) isEqual:[@"base\n" dataUsingEncoding:NSUTF8StringEncoding]];
	baseReady &= WriteUploadedMarker(sessionURL, @"PEER_READY", timeout, &error);
	if (!baseReady) {
		ReportError(@"FAIL", @"AV-10-conflict-peer", error);
		return 1;
	}
	BOOL go = WaitFor(timeout, ^BOOL{
		NSDictionary *catalog = CoordinatedCatalog(sessionURL, NULL);
		return [catalog objectForKey:@"GO"] || [catalog objectForKey:@"ABORT"];
	});
	if (!go) {
		Report(@"FAIL", @"AV-10-conflict-peer", @"host supplied neither GO nor ABORT");
		return 1;
	}
	if ([[CoordinatedCatalog(sessionURL, NULL) allKeys] containsObject:@"ABORT"]) {
		WriteUploadedMarker(sessionURL, @"FINISHED", timeout, NULL);
		Report(@"PASS", @"AV-10-conflict-peer", @"host selected ordinary-sync fallback");
		return 0;
	}
	NSData *peerPayload = [@"peer-newer\n" dataUsingEncoding:NSUTF8StringEncoding];
	BOOL wrote = CoordinatedWrite(itemURL, peerPayload, &error) && WaitUntilUploaded(itemURL, timeout) &&
		WriteUploadedMarker(sessionURL, @"PEER_DONE", timeout, &error);
	if (wrote)
		wrote = WaitForMarker(sessionURL, @"ACK", timeout);
	if (wrote)
		wrote = WriteUploadedMarker(sessionURL, @"FINISHED", timeout, &error);
	Report(wrote ? @"PASS" : @"FAIL", @"AV-10-conflict-peer",
		wrote ? @"peer installed and uploaded the newer server version" : [NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
	return wrote ? 0 : 1;
}

static int RunSyncConflictHost(NSURL *rootURL, NSTimeInterval timeout) API_AVAILABLE(macos(26.0));
static int RunSyncConflictHost(NSURL *rootURL, NSTimeInterval timeout) {
	NSURL *sessionURL = SyncConflictSessionURL(rootURL);
	if ([[NSFileManager defaultManager] fileExistsAtPath:[sessionURL path]])
		CoordinatedDelete(sessionURL, NULL);
	NSError *error = nil;
	NSURL *itemURL = [sessionURL URLByAppendingPathComponent:@"checkpoint.bin"];
	BOOL ready = CoordinatedCreateDirectory(sessionURL, &error) &&
		CoordinatedWrite(itemURL, [@"base\n" dataUsingEncoding:NSUTF8StringEncoding], &error) &&
		WaitUntilUploaded(itemURL, timeout) && WriteUploadedMarker(sessionURL, @"READY", timeout, &error);
	if (!ready) {
		ReportError(@"FAIL", @"AV-10-conflict-host", error);
		return 1;
	}
	Report(@"READY", @"AV-10-conflict-host", @"run sync-conflict-peer on the second Mac");
	if (!WaitForMarker(sessionURL, @"PEER_READY", timeout)) {
		Report(@"FAIL", @"AV-10-conflict-host", @"peer did not materialize the base");
		return 1;
	}
	NSNumber *supportedNumber = ResourceValue(itemURL, NSURLUbiquitousItemSupportedSyncControlsKey, &error);
	NSFileManagerSupportedSyncControls supported = [supportedNumber unsignedIntegerValue];
	BOOL controls = !error && (supported & (NSFileManagerSupportedSyncControlsPauseSync |
		NSFileManagerSupportedSyncControlsFailUploadOnConflict)) ==
		(NSFileManagerSupportedSyncControlsPauseSync | NSFileManagerSupportedSyncControlsFailUploadOnConflict);
	NSError *pauseError = controls ? PauseSyncWhenStable(itemURL, timeout) : nil;
	if (!controls || pauseError) {
		WriteUploadedMarker(sessionURL, @"ABORT", timeout, NULL);
		WaitForMarker(sessionURL, @"FINISHED", timeout);
		Report(@"PASS", @"AV-10-conflict-fallback", [NSString stringWithFormat:
			@"advertised=0x%lx pause-error=%@", (unsigned long)supported, ErrorCode(pauseError ?: error)]);
		CoordinatedDelete(sessionURL, NULL);
		return 0;
	}

	NSData *hostPayload = [@"host-local\n" dataUsingEncoding:NSUTF8StringEncoding];
	BOOL localReady = CoordinatedInPlaceWrite(itemURL, hostPayload, &error) &&
		WriteUploadedMarker(sessionURL, @"GO", timeout, &error) && WaitForMarker(sessionURL, @"PEER_DONE", timeout);
	NSFileVersion *remoteVersion = nil;
	NSData *remotePayload = nil;
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (localReady && ![remotePayload isEqual:[@"peer-newer\n" dataUsingEncoding:NSUTF8StringEncoding]] &&
		[deadline timeIntervalSinceNow] > 0.0) {
		remoteVersion = WaitForAsyncVersion(MIN(60.0, timeout),
			^(void (^completion)(NSFileVersion *, NSError *)) {
				[[NSFileManager defaultManager] fetchLatestRemoteVersionOfItemAtURL:itemURL completionHandler:completion];
			}, &error);
		NSURL *remoteURL = [remoteVersion URL];
		remotePayload = remoteURL ? ([remoteURL isEqual:itemURL] ? CoordinatedRead(itemURL, NULL) :
			CoordinatedRead(remoteURL, NULL)) : nil;
		if (![remotePayload isEqual:[@"peer-newer\n" dataUsingEncoding:NSUTF8StringEncoding]])
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
	}
	NSError *uploadError = nil;
	NSFileVersion *uploadedVersion = remotePayload ? WaitForAsyncVersion(timeout,
		^(void (^completion)(NSFileVersion *, NSError *)) {
			[[NSFileManager defaultManager] uploadLocalVersionOfUbiquitousItemAtURL:itemURL
				withConflictResolutionPolicy:NSFileManagerUploadConflictPolicyFailOnConflict completionHandler:completion];
		}, &uploadError) : nil;
	NSError *underlying = [[uploadError userInfo] objectForKey:NSUnderlyingErrorKey];
	BOOL conflict = remotePayload && !uploadedVersion && uploadError &&
		[[underlying domain] isEqualToString:NSFileProviderErrorDomain] &&
		[underlying code] == NSFileProviderErrorLocalVersionConflictingWithServer;
	BOOL localPreserved = [CoordinatedRead(itemURL, NULL) isEqual:hostPayload];
	Report(conflict && localPreserved ? @"PASS" : @"FAIL", @"AV-10-conflict",
		conflict && localPreserved ? @"fail-on-conflict rejected stale local upload and preserved both readable inputs" :
		[NSString stringWithFormat:@"remote=%d local=%d error=%@", remotePayload != nil, localPreserved, ErrorCode(uploadError ?: error)]);
	NSError *resumeError = WaitForAsyncError(timeout, ^(void (^completion)(NSError *)) {
		[[NSFileManager defaultManager] resumeSyncForUbiquitousItemAtURL:itemURL
			withBehavior:NSFileManagerResumeSyncBehaviorPreserveLocalChanges completionHandler:completion];
	});
	BOOL finished = !resumeError && WriteUploadedMarker(sessionURL, @"ACK", timeout, &error) &&
		WaitForMarker(sessionURL, @"FINISHED", timeout);
	Report(finished ? @"PASS" : @"FAIL", @"AV-10-conflict-resume",
		finished ? @"sync resumed after the deliberate conflict" : [NSString stringWithFormat:@"error=%@", ErrorCode(resumeError ?: error)]);
	CoordinatedDelete(sessionURL, NULL);
	return failures == 0 ? 0 : 1;
}

static int CleanupSyncConflictSession(NSURL *rootURL) {
	NSError *error = nil;
	NSURL *sessionURL = SyncConflictSessionURL(rootURL);
	if (CoordinatedDelete(sessionURL, &error) ||
		([[error domain] isEqualToString:NSCocoaErrorDomain] && [error code] == NSFileNoSuchFileError)) {
		Report(@"PASS", @"CLEANUP", @"sync-conflict test subtree absent or removed");
		return 0;
	}
	ReportError(@"FAIL", @"CLEANUP", error);
	return 1;
}

static int CleanupLocalSession(NSURL *rootURL) {
	NSArray *names = [NSArray arrayWithObjects:@"nv-api-contract-local", @"nv-api-contract-local-moved",
		@"nv-api-contract-legacy-upload", @"nv-api-contract-pause-lifecycle",
		@"nv-api-contract-path-a", @"nv-api-contract-path-b", nil];
	for (NSString *name in names) {
		NSError *error = nil;
		NSURL *url = [rootURL URLByAppendingPathComponent:name isDirectory:YES];
		if (!CoordinatedDelete(url, &error) &&
			!([[error domain] isEqualToString:NSCocoaErrorDomain] && [error code] == NSFileNoSuchFileError)) {
			ReportError(@"FAIL", @"CLEANUP", error);
			return 1;
		}
	}
	RemoveContractItemIfPresent([rootURL URLByAppendingPathComponent:
		@".nv-api-contract-path-move-marker"]);
	Report(@"PASS", @"CLEANUP", @"local rendezvous absent or removed");
	return 0;
}

static int CleanupRemoteSession(NSURL *rootURL) {
	NSURL *sessionURL = [rootURL URLByAppendingPathComponent:@"nv-api-contract-remote" isDirectory:YES];
	NSError *error = nil;
	if (CoordinatedDelete(sessionURL, &error) ||
		([[error domain] isEqualToString:NSCocoaErrorDomain] && [error code] == NSFileNoSuchFileError)) {
		Report(@"PASS", @"CLEANUP", @"remote rendezvous absent or removed");
		return 0;
	}
	ReportError(@"FAIL", @"CLEANUP", error);
	return 1;
}

static NSDictionary *CopyProviderIdentity(NSURL *url, NSTimeInterval timeout, NSError **outError) {
	__block NSFileProviderItemIdentifier itemIdentifier = nil;
	__block NSFileProviderDomainIdentifier domainIdentifier = nil;
	__block NSError *resultError = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	[NSFileProviderManager getIdentifierForUserVisibleFileAtURL:url completionHandler:
		^(NSFileProviderItemIdentifier item, NSFileProviderDomainIdentifier domain, NSError *error) {
			itemIdentifier = [item retain];
			domainIdentifier = [domain retain];
			resultError = [error retain];
			dispatch_semaphore_signal(semaphore);
		}];
	BOOL completed = WaitSemaphore(semaphore, timeout);
	NSDictionary *identity = completed && itemIdentifier && domainIdentifier && !resultError ?
		[NSDictionary dictionaryWithObjectsAndKeys:itemIdentifier, @"item", domainIdentifier, @"domain", nil] : nil;
	if (!identity && outError) {
		NSError *error = resultError ?: [NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
		*outError = [[error retain] autorelease];
	}
	[itemIdentifier release];
	[domainIdentifier release];
	[resultError release];
	return identity;
}

static NSArray *CopyFileProviderDomains(NSTimeInterval timeout, NSError **outError) {
	__block NSArray *resultDomains = nil;
	__block NSError *resultError = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	[NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains,
		NSError *error) {
		resultDomains = [domains copy];
		resultError = [error retain];
		dispatch_semaphore_signal(semaphore);
	}];
	BOOL completed = WaitSemaphore(semaphore, timeout);
	if ((!completed || !resultDomains || resultError) && outError) {
		NSError *error = resultError ?:
			[NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
		*outError = [[error retain] autorelease];
	}
	[resultError release];
	return [resultDomains autorelease];
}

static NSURL *CopyReverseProviderURL(NSDictionary *identity, NSTimeInterval timeout,
	NSError **outError) {
	NSError *error = nil;
	NSArray *domains = CopyFileProviderDomains(timeout, &error);
	NSFileProviderDomain *matchingDomain = nil;
	for (NSFileProviderDomain *domain in domains) {
		if ([(NSObject *)[domain identifier] isEqual:[identity objectForKey:@"domain"]]) {
			matchingDomain = domain;
			break;
		}
	}
	NSFileProviderManager *manager = matchingDomain ?
		[NSFileProviderManager managerForDomain:matchingDomain] : nil;
	if (!manager) {
		if (outError)
			*outError = error ?: [NSError errorWithDomain:@"NVAPIContractTest" code:ENOENT userInfo:nil];
		return nil;
	}
	__block NSURL *resultURL = nil;
	__block NSError *resultError = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	[manager getUserVisibleURLForItemIdentifier:[identity objectForKey:@"item"]
		completionHandler:^(NSURL *url, NSError *requestError) {
			resultURL = [url retain];
			resultError = [requestError retain];
			dispatch_semaphore_signal(semaphore);
		}];
	BOOL completed = WaitSemaphore(semaphore, timeout);
	if ((!completed || !resultURL || resultError) && outError) {
		NSError *requestError = resultError ?:
			[NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
		*outError = [[requestError retain] autorelease];
	}
	[resultError release];
	return [resultURL autorelease];
}

static BOOL ErrorContainsDomainCode(NSError *error, NSString *domain, NSInteger code) {
	while (error) {
		if ([[error domain] isEqualToString:domain] && [error code] == code)
			return YES;
		error = [[error userInfo] objectForKey:NSUnderlyingErrorKey];
	}
	return NO;
}

static int RunProviderReverseChild(NSURL *url, NSTimeInterval timeout) {
	NSError *error = nil;
	NSDictionary *identity = CopyProviderIdentity(url, timeout, &error);
	NSURL *reverseURL = identity ? CopyReverseProviderURL(identity, timeout, &error) : nil;
	if (!reverseURL && ErrorContainsDomainCode(error, NSFileProviderErrorDomain,
		NSFileProviderErrorProviderNotFound)) {
		Report(@"PASS", @"AV-09-reverse-unavailable",
			@"consumer process was denied a provider-domain manager; production must keep continuity unknown");
		return 0;
	}
	BOOL accessed = reverseURL && [reverseURL startAccessingSecurityScopedResource];
	NSDictionary *roundTrip = reverseURL ? CopyProviderIdentity(reverseURL, timeout, &error) : nil;
	BOOL sameIdentity = ProviderIdentitiesEqual(identity, roundTrip);
	Report(reverseURL && accessed && sameIdentity ? @"PASS" : @"FAIL", @"AV-09-reverse",
		reverseURL && accessed && sameIdentity ? @"forward identity reversed to the same provider item and domain" :
		[NSString stringWithFormat:@"security-scope=%d error=%@", accessed, ErrorCode(error)]);

	NSError *readError = nil;
	NSData *data = reverseURL ? CoordinatedRead(reverseURL, &readError) : nil;
	BOOL deadlocked = ErrorContainsDomainCode(readError, NSPOSIXErrorDomain, EDEADLK);
	Report(deadlocked ? @"PASS" : @"OBSERVE", @"AV-09-reverse-materialization",
		deadlocked ? @"reverse lookup caused the documented EDEADLK materialization guard in the disposable process" :
		[NSString stringWithFormat:@"read=%d error=%@", data != nil, ErrorCode(readError)]);
	if (accessed)
		[reverseURL stopAccessingSecurityScopedResource];
	return failures == 0 ? 0 : 1;
}

static void TestProviderIdentity(NSURL *rootURL, NSURL *childURL, NSTimeInterval timeout) {
	NSError *error = nil;
	NSDictionary *first = CopyProviderIdentity(rootURL, timeout, &error);
	NSDictionary *second = CopyProviderIdentity(rootURL, timeout, &error);
	NSDictionary *child = CopyProviderIdentity(childURL, timeout, &error);
	BOOL stable = first && second && child &&
		[(NSObject *)[first objectForKey:@"item"] isEqual:[second objectForKey:@"item"]] &&
		[(NSObject *)[first objectForKey:@"domain"] isEqual:[second objectForKey:@"domain"]] &&
		[(NSObject *)[first objectForKey:@"domain"] isEqual:[child objectForKey:@"domain"]];
	if (stable)
		Report(@"PASS", @"AV-09", @"root identity was repeat-stable and child shared its provider domain");
	else
		ReportError(@"OBSERVE", @"AV-09", error);
}

static NSError *WaitForAsyncError(NSTimeInterval timeout, void (^starter)(void (^)(NSError *))) {
	__block NSError *resultError = nil;
	__block BOOL completed = NO;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	starter(^(NSError *error) {
		resultError = [error retain];
		completed = YES;
		dispatch_semaphore_signal(semaphore);
	});
	if (!WaitSemaphore(semaphore, timeout) || !completed)
		return [NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
	return [resultError autorelease];
}

static NSFileVersion *WaitForAsyncVersion(NSTimeInterval timeout,
	void (^starter)(void (^)(NSFileVersion *, NSError *)), NSError **outError) {
	__block NSFileVersion *resultVersion = nil;
	__block NSError *resultError = nil;
	__block BOOL completed = NO;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	starter(^(NSFileVersion *version, NSError *error) {
		resultVersion = [version retain];
		resultError = [error retain];
		completed = YES;
		dispatch_semaphore_signal(semaphore);
	});
	if (!WaitSemaphore(semaphore, timeout) || !completed) {
		[resultVersion release];
		[resultError release];
		if (outError)
			*outError = [NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
		return nil;
	}
	if (outError)
		*outError = [[resultError retain] autorelease];
	[resultError release];
	return [resultVersion autorelease];
}

static BOOL SameVersion(NSFileVersion *first, NSFileVersion *second) {
	id firstIdentifier = [first persistentIdentifier];
	id secondIdentifier = [second persistentIdentifier];
	return firstIdentifier && secondIdentifier && [(NSObject *)firstIdentifier isEqual:secondIdentifier];
}

static NSString *SyncControlState(NSURL *url) API_AVAILABLE(macos(26.0));
static NSString *SyncControlState(NSURL *url) {
	NSArray *keys = [NSArray arrayWithObjects:NSURLIsRegularFileKey, NSURLIsDirectoryKey,
		NSURLIsPackageKey, NSURLIsUbiquitousItemKey, NSURLUbiquitousItemDownloadingStatusKey,
		NSURLUbiquitousItemIsUploadedKey, NSURLUbiquitousItemIsUploadingKey,
		NSURLUbiquitousItemUploadingErrorKey, NSURLUbiquitousItemSupportedSyncControlsKey,
		NSURLUbiquitousItemIsSyncPausedKey, nil];
	NSError *error = nil;
	NSDictionary *values = [[FreshURL(url) absoluteURL] resourceValuesForKeys:keys error:&error];
	return [NSString stringWithFormat:@"regular=%@ directory=%@ package=%@ ubiquitous=%@ download=%@ uploaded=%@ uploading=%@ upload-error=%@ controls=%@ paused=%@ resource-error=%@",
		[values objectForKey:NSURLIsRegularFileKey], [values objectForKey:NSURLIsDirectoryKey],
		[values objectForKey:NSURLIsPackageKey], [values objectForKey:NSURLIsUbiquitousItemKey],
		[values objectForKey:NSURLUbiquitousItemDownloadingStatusKey],
		[values objectForKey:NSURLUbiquitousItemIsUploadedKey],
		[values objectForKey:NSURLUbiquitousItemIsUploadingKey],
		ErrorCode([values objectForKey:NSURLUbiquitousItemUploadingErrorKey]),
		[values objectForKey:NSURLUbiquitousItemSupportedSyncControlsKey],
		[values objectForKey:NSURLUbiquitousItemIsSyncPausedKey], ErrorCode(error)];
}

static NSError *PauseSync(NSURL *url, NSTimeInterval timeout) API_AVAILABLE(macos(26.0));
static NSError *PauseSync(NSURL *url, NSTimeInterval timeout) {
	return WaitForAsyncError(timeout, ^(void (^completion)(NSError *)) {
		[[NSFileManager defaultManager] pauseSyncForUbiquitousItemAtURL:url completionHandler:completion];
	});
}

static BOOL IsBusyError(NSError *error) {
	NSError *underlying = [[error userInfo] objectForKey:NSUnderlyingErrorKey];
	return ([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == EBUSY) ||
		([[underlying domain] isEqualToString:NSPOSIXErrorDomain] && [underlying code] == EBUSY);
}

static NSError *PauseSyncWhenStable(NSURL *url, NSTimeInterval timeout) {
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	NSError *error = nil;
	do {
		error = PauseSync(url, MIN(30.0, MAX(1.0, [deadline timeIntervalSinceNow])));
		if (!error || !IsBusyError(error))
			return error;
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
	} while ([deadline timeIntervalSinceNow] > 0.0);
	return error;
}

static int RunSyncControlProbe(NSURL *rootURL, NSTimeInterval timeout) API_AVAILABLE(macos(26.0));
static int RunSyncControlProbe(NSURL *rootURL, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	Report(@"OBSERVE", @"SYNC-CONTROL-CONTEXT", [NSString stringWithFormat:@"bundle-id=%@",
		[[NSBundle mainBundle] bundleIdentifier] ?: @"none"]);
	NSURL *sessionURL = [rootURL URLByAppendingPathComponent:@"nv-api-contract-sync-control-probe" isDirectory:YES];
	if ([manager fileExistsAtPath:[sessionURL path]])
		CoordinatedDelete(sessionURL, NULL);
	NSError *error = nil;
	NSURL *flatURL = [sessionURL URLByAppendingPathComponent:@"flat.txt" isDirectory:NO];
	BOOL ready = CoordinatedCreateDirectory(sessionURL, &error) &&
		CoordinatedWrite(flatURL, [@"flat\n" dataUsingEncoding:NSUTF8StringEncoding], &error) &&
		WaitUntilUploaded(flatURL, timeout) &&
		[manager startDownloadingUbiquitousItemAtURL:flatURL error:&error] &&
		WaitUntilCurrent(flatURL, timeout);
	if (!ready) {
		ReportError(@"FAIL", @"SYNC-CONTROL-PROBE-SETUP", error);
		CoordinatedDelete(sessionURL, NULL);
		return 1;
	}

	Report(@"OBSERVE", @"SYNC-CONTROL-FLAT-BEFORE", SyncControlState(flatURL));
	NSError *flatPauseError = PauseSyncWhenStable(flatURL, timeout);
	Report(flatPauseError ? @"FAIL" : @"PASS", @"SYNC-CONTROL-FLAT-PAUSE",
		[NSString stringWithFormat:@"error=%@ description=%@ userInfo=%@", ErrorCode(flatPauseError),
			[flatPauseError localizedDescription], [flatPauseError userInfo]]);
	Report(@"OBSERVE", @"SYNC-CONTROL-FLAT-AFTER", SyncControlState(flatURL));
	if (!flatPauseError) {
		NSError *resumeError = WaitForAsyncError(timeout, ^(void (^completion)(NSError *)) {
			[manager resumeSyncForUbiquitousItemAtURL:flatURL
				withBehavior:NSFileManagerResumeSyncBehaviorPreserveLocalChanges completionHandler:completion];
		});
		Report(resumeError ? @"FAIL" : @"PASS", @"SYNC-CONTROL-FLAT-RESUME",
			[NSString stringWithFormat:@"error=%@", ErrorCode(resumeError)]);
	}
	CoordinatedDelete(sessionURL, NULL);
	return flatPauseError ? 1 : 0;
}

static NSURL *PauseLifecycleSessionURL(NSURL *rootURL) {
	return [rootURL URLByAppendingPathComponent:@"nv-api-contract-pause-lifecycle" isDirectory:YES];
}

static int RunPauseLifecyclePrepare(NSURL *rootURL, NSTimeInterval timeout) API_AVAILABLE(macos(26.0));
static int RunPauseLifecyclePrepare(NSURL *rootURL, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *sessionURL = PauseLifecycleSessionURL(rootURL);
	if ([manager fileExistsAtPath:[sessionURL path]])
		CoordinatedDelete(sessionURL, NULL);
	NSURL *url = [sessionURL URLByAppendingPathComponent:@"checkpoint.bin"];
	NSError *error = nil;
	BOOL ready = CoordinatedCreateDirectory(sessionURL, &error) &&
		CoordinatedWrite(url, PatternData(32768, 0xB1), &error) && WaitUntilUploaded(url, timeout);
	if (ready)
		error = PauseSyncWhenStable(url, timeout);
	BOOL changed = ready && !error && CoordinatedInPlaceWrite(url, PatternData(32769, 0xB2), &error);
	NSNumber *paused = changed ? ResourceValue(url, NSURLUbiquitousItemIsSyncPausedKey, NULL) : nil;
	BOOL prepared = changed && [paused boolValue];
	Report(prepared ? @"PASS" : @"FAIL", @"AV-10-lifecycle-prepare",
		prepared ? @"paused item retained local changes before app exit" :
		[NSString stringWithFormat:@"paused=%@ error=%@", paused, ErrorCode(error)]);
	return prepared ? 0 : 1;
}

static int RunPauseLifecycleRepair(NSURL *rootURL, NSTimeInterval timeout) API_AVAILABLE(macos(26.0));
static int RunPauseLifecycleRepair(NSURL *rootURL, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *sessionURL = PauseLifecycleSessionURL(rootURL);
	NSURL *url = [sessionURL URLByAppendingPathComponent:@"checkpoint.bin"];
	NSNumber *paused = ResourceValue(url, NSURLUbiquitousItemIsSyncPausedKey, NULL);
	NSData *data = CoordinatedRead(url, NULL);
	NSError *resumeError = WaitForAsyncError(timeout, ^(void (^completion)(NSError *)) {
		[manager resumeSyncForUbiquitousItemAtURL:url
			withBehavior:NSFileManagerResumeSyncBehaviorPreserveLocalChanges completionHandler:completion];
	});
	BOOL repaired = [paused boolValue] && [data isEqual:PatternData(32769, 0xB2)] && !resumeError &&
		WaitUntilUploaded(url, timeout);
	Report(repaired ? @"PASS" : @"FAIL", @"AV-10-lifecycle-repair",
		repaired ? @"fresh app launch observed and resumed the paused local version" :
		[NSString stringWithFormat:@"paused=%@ exact=%d error=%@", paused,
			[data isEqual:PatternData(32769, 0xB2)], ErrorCode(resumeError)]);
	CoordinatedDelete(sessionURL, NULL);
	return repaired ? 0 : 1;
}

static void TestMacOS26SyncControls(NSURL *url, NSTimeInterval timeout) API_AVAILABLE(macos(26.0));
static void TestMacOS26SyncControls(NSURL *url, NSTimeInterval timeout) {
	NSError *resourceError = nil;
	NSNumber *supportedNumber = ResourceValue(url, NSURLUbiquitousItemSupportedSyncControlsKey, &resourceError);
	NSFileManagerSupportedSyncControls supported = [supportedNumber unsignedIntegerValue];
	Report(resourceError ? @"OBSERVE" : @"PASS", @"AV-10-capability",
		[NSString stringWithFormat:@"advertised=0x%lx error=%@", (unsigned long)supported, ErrorCode(resourceError)]);
	if (resourceError || (supported & (NSFileManagerSupportedSyncControlsPauseSync |
		NSFileManagerSupportedSyncControlsFailUploadOnConflict)) !=
		(NSFileManagerSupportedSyncControlsPauseSync | NSFileManagerSupportedSyncControlsFailUploadOnConflict)) {
		Report(@"PASS", @"AV-10-fallback", @"ordinary synchronization selected because exact controls were not advertised");
		return;
	}

	NSFileManager *manager = [NSFileManager defaultManager];
	NSError *pauseError = PauseSyncWhenStable(url, timeout);
	if (pauseError) {
		ReportError(@"OBSERVE", @"AV-10", pauseError);
		Report(@"PASS", @"AV-10-fallback", @"pause failed before acquisition; ordinary synchronization remains available");
		return;
	}

	BOOL paused = YES;
	NSNumber *pausedValue = ResourceValue(url, NSURLUbiquitousItemIsSyncPausedKey, &resourceError);
	Report(!resourceError && [pausedValue boolValue] ? @"PASS" : @"FAIL", @"AV-10-paused-state",
		!resourceError && [pausedValue boolValue] ? @"successful pause became observable" :
		[NSString stringWithFormat:@"paused=%@ error=%@", pausedValue, ErrorCode(resourceError)]);
	NSError *writeError = nil;
	NSData *replacement = PatternData(65537, 0x91);
	if (!CoordinatedInPlaceWrite(url, replacement, &writeError))
		ReportError(@"FAIL", @"AV-10", writeError);
	else {
		NSFileVersion *installedVersion = [NSFileVersion currentVersionOfItemAtURL:url];
		__block NSFileVersion *uploadedVersion = nil;
		__block NSError *uploadError = nil;
		__block BOOL uploadCompleted = NO;
		dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
		[manager uploadLocalVersionOfUbiquitousItemAtURL:url
			withConflictResolutionPolicy:NSFileManagerUploadConflictPolicyFailOnConflict
			completionHandler:^(NSFileVersion *version, NSError *error) {
				uploadedVersion = [version retain];
				uploadError = [error retain];
				uploadCompleted = YES;
				dispatch_semaphore_signal(semaphore);
		}];
		BOOL returned = WaitSemaphore(semaphore, timeout);
		NSData *readBack = CoordinatedRead(url, &writeError);
		BOOL sameVersion = SameVersion(installedVersion, uploadedVersion);
		if (returned && uploadCompleted && !uploadError && sameVersion && [readBack isEqual:replacement])
			Report(@"PASS", @"AV-10", @"pause/in-place-write/upload returned the exact installed and read-back-verified version");
		else
			ReportError(@"FAIL", @"AV-10", uploadError ?: writeError ?:
				[NSError errorWithDomain:@"NVAPIContractTest" code:EINVAL userInfo:nil]);
		[uploadedVersion release];
		[uploadError release];
	}

	if (paused) {
		NSError *resumeError = nil;
		for (NSUInteger attempt = 0; attempt < 3; attempt++) {
			resumeError = WaitForAsyncError(timeout, ^(void (^completion)(NSError *)) {
				[manager resumeSyncForUbiquitousItemAtURL:url
					withBehavior:NSFileManagerResumeSyncBehaviorPreserveLocalChanges completionHandler:completion];
			});
			if (!resumeError)
				break;
			[NSThread sleepForTimeInterval:0.5];
		}
		if (resumeError)
			ReportError(@"FAIL", @"AV-10-resume", resumeError);
		else
			Report(@"PASS", @"AV-10-resume", @"sync resumed with local changes preserved");
	}
}

static void TestMacOS26AtomicReplacement(NSURL *url, NSTimeInterval timeout) API_AVAILABLE(macos(26.0));
static void TestMacOS26AtomicReplacement(NSURL *url, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSError *error = PauseSyncWhenStable(url, timeout);
	BOOL replaced = !error && CoordinatedWrite(url, PatternData(65539, 0xA1), &error);
	NSNumber *paused = replaced ? ResourceValue(url, NSURLUbiquitousItemIsSyncPausedKey, NULL) : nil;
	NSError *resumeError = replaced ? WaitForAsyncError(timeout, ^(void (^completion)(NSError *)) {
		[manager resumeSyncForUbiquitousItemAtURL:url
			withBehavior:NSFileManagerResumeSyncBehaviorPreserveLocalChanges completionHandler:completion];
	}) : nil;
	BOOL replacementLostPause = replaced && [[resumeError domain] isEqualToString:NSCocoaErrorDomain] &&
		[resumeError code] == NSFeatureUnsupportedError;
	Report(replacementLostPause ? @"PASS" : @"OBSERVE", @"AV-10-atomic-replacement",
		replacementLostPause ? [NSString stringWithFormat:
			@"replacement was not resumably paused; resource-key paused=%@ but resume reported featureUnsupported", paused] :
		[NSString stringWithFormat:@"replaced=%d paused=%@ error=%@", replaced, paused, ErrorCode(resumeError ?: error)]);

	NSURL *safeURL = [[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"foundation-safe-save.bin"];
	NSData *baseline = UniquePatternData(256 * 1024, 0xA2);
	NSData *replacement = UniquePatternData(512 * 1024, 0xA3);
	error = nil;
	BOOL ready = CoordinatedWrite(safeURL, baseline, &error) && WaitUntilUploaded(safeURL, timeout);
	NSNumber *controlNumber = ResourceValue(safeURL, NSURLUbiquitousItemSupportedSyncControlsKey, NULL);
	NSFileManagerSupportedSyncControls controls = [controlNumber unsignedIntegerValue];
	BOOL exactUploadSupported = (controls & NSFileManagerSupportedSyncControlsFailUploadOnConflict) != 0;
	NSURL *fileReferenceURL = ready ? [safeURL fileReferenceURL] : nil;
	NSDictionary *identityBefore = fileReferenceURL ? CopyProviderIdentity(fileReferenceURL, timeout, NULL) : nil;
	NSError *pauseError = fileReferenceURL ? PauseSyncWhenStable(fileReferenceURL, timeout) : error;
	NSURL *resultURL = pauseError ? nil : CoordinatedSafeReplace(fileReferenceURL, replacement, &error);
	NSDictionary *identityAfter = resultURL ? CopyProviderIdentity(resultURL, timeout, NULL) : nil;
	NSFileVersion *installedVersion = resultURL ? [NSFileVersion currentVersionOfItemAtURL:resultURL] : nil;
	NSError *uploadError = nil;
	NSFileVersion *uploadedVersion = resultURL && exactUploadSupported ? WaitForAsyncVersion(timeout,
		^(void (^completion)(NSFileVersion *, NSError *)) {
			[manager uploadLocalVersionOfUbiquitousItemAtURL:resultURL
				withConflictResolutionPolicy:NSFileManagerUploadConflictPolicyFailOnConflict completionHandler:completion];
		}, &uploadError) : nil;
	NSError *safeResumeError = resultURL ? WaitForAsyncError(timeout, ^(void (^completion)(NSError *)) {
		[manager resumeSyncForUbiquitousItemAtURL:resultURL
			withBehavior:NSFileManagerResumeSyncBehaviorPreserveLocalChanges completionHandler:completion];
	}) : nil;
	BOOL identityPreserved = identityBefore && [identityBefore isEqual:identityAfter];
	BOOL exactVersion = !exactUploadSupported || SameVersion(installedVersion, uploadedVersion);
	BOOL referenceSurvived = fileReferenceURL && [fileReferenceURL checkResourceIsReachableAndReturnError:NULL] &&
		[CoordinatedRead(fileReferenceURL, NULL) isEqual:replacement];
	NSURL *refreshedResultReferenceURL = [resultURL fileReferenceURL];
	NSURL *refreshedOriginalPathReferenceURL = [safeURL fileReferenceURL];
	NSURL *canonicalResultURL = [NSURL fileURLWithPath:[resultURL path] isDirectory:NO];
	NSURL *refreshedCanonicalReferenceURL = [canonicalResultURL fileReferenceURL];
	BOOL refreshedResultReferenceWorks = [refreshedResultReferenceURL isFileReferenceURL] &&
		[CoordinatedRead(refreshedResultReferenceURL, NULL) isEqual:replacement];
	BOOL refreshedOriginalPathReferenceWorks = [refreshedOriginalPathReferenceURL isFileReferenceURL] &&
		[CoordinatedRead(refreshedOriginalPathReferenceURL, NULL) isEqual:replacement];
	BOOL refreshedCanonicalReferenceWorks = [refreshedCanonicalReferenceURL isFileReferenceURL] &&
		[CoordinatedRead(refreshedCanonicalReferenceURL, NULL) isEqual:replacement];
	BOOL refreshedReferenceWorks = refreshedResultReferenceWorks ||
		refreshedOriginalPathReferenceWorks || refreshedCanonicalReferenceWorks;
	BOOL safeSaveWorked = resultURL && identityPreserved && refreshedReferenceWorks && exactVersion &&
		!uploadError && !safeResumeError && [CoordinatedRead(resultURL, NULL) isEqual:replacement];
	Report(safeSaveWorked ? @"PASS" : @"OBSERVE", @"AV-10-foundation-safe-save",
		[NSString stringWithFormat:@"input-reference=%d result-reference=%d old-reference-survived=%d refreshed-reference(result/original/canonical)=%d/%d/%d result=%@ identity-preserved=%d exact-version=%@ upload=%@ upload-error=%@ resume-error=%@",
			[fileReferenceURL isFileReferenceURL], [resultURL isFileReferenceURL], referenceSurvived,
			refreshedResultReferenceWorks, refreshedOriginalPathReferenceWorks, refreshedCanonicalReferenceWorks,
			[resultURL path], identityPreserved, exactUploadSupported ? (exactVersion ? @"yes" : @"no") : @"not-advertised",
			[uploadedVersion persistentIdentifier],
			ErrorCode(uploadError ?: error), ErrorCode(safeResumeError)]);
}

static int RunLegacyUploadTransition(NSURL *rootURL, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	if (![manager isUbiquitousItemAtURL:rootURL]) {
		Report(@"SKIP", @"AV-11", @"selected root does not expose ubiquitous upload status");
		return 0;
	}
	NSURL *sessionURL = [rootURL URLByAppendingPathComponent:@"nv-api-contract-legacy-upload" isDirectory:YES];
	if ([manager fileExistsAtPath:[sessionURL path]])
		CoordinatedDelete(sessionURL, NULL);
	NSError *error = nil;
	if (!CoordinatedCreateDirectory(sessionURL, &error)) {
		ReportError(@"FAIL", @"AV-11-setup", error);
		return 1;
	}
	NSURL *url = [sessionURL URLByAppendingPathComponent:@"checkpoint.bin"];
	NSData *baseline = UniquePatternData(256 * 1024, 0xB1);
	if (!CoordinatedWrite(url, baseline, &error) || !WaitUntilUploaded(url, timeout)) {
		ReportError(@"FAIL", @"AV-11-setup", error);
		CoordinatedDelete(sessionURL, NULL);
		return 1;
	}

	NVContractPresenter *presenter = [[[NVContractPresenter alloc] initWithURL:url] autorelease];
	[NSFileCoordinator addFilePresenter:presenter];
	NSData *replacement = UniquePatternData(4 * 1024 * 1024, 0xC1);
	BOOL wrote = CoordinatedWrite(url, replacement, &error);
	NSFileVersion *installedVersion = wrote ? [NSFileVersion currentVersionOfItemAtURL:url] : nil;
	__block BOOL sawPending = NO;
	__block BOOL sawCompleteAfterPending = NO;
	__block NSError *uploadError = nil;
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (wrote && [deadline timeIntervalSinceNow] > 0.0) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		[uploadError release];
		uploadError = [ResourceValue(url, NSURLUbiquitousItemUploadingErrorKey, NULL) retain];
		NSNumber *uploaded = ResourceValue(url, NSURLUbiquitousItemIsUploadedKey, NULL);
		NSNumber *uploading = ResourceValue(url, NSURLUbiquitousItemIsUploadingKey, NULL);
		if (![uploaded boolValue] || [uploading boolValue])
			sawPending = YES;
		if (sawPending && [uploaded boolValue] && ![uploading boolValue] && !uploadError)
			sawCompleteAfterPending = YES;
		BOOL done = sawCompleteAfterPending || uploadError != nil;
		[pool drain];
		if (done)
			break;
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
	NSFileVersion *finalVersion = [NSFileVersion currentVersionOfItemAtURL:url];
	NSData *readBack = CoordinatedRead(url, &error);
	BOOL exact = sawCompleteAfterPending && !uploadError && SameVersion(installedVersion, finalVersion) &&
		[readBack isEqual:replacement];
	if (exact)
		Report(@"PASS", @"AV-11", @"observed post-install pending-to-uploaded transition for one unchanged exact local version");
	else
		Report(@"OBSERVE", @"AV-11", [NSString stringWithFormat:
			@"qualification unavailable pending=%d complete=%d same-version=%d exact-bytes=%d error=%@",
			sawPending, sawCompleteAfterPending, SameVersion(installedVersion, finalVersion),
			[readBack isEqual:replacement], ErrorCode(uploadError ?: error)]);
	Report([presenter eventCount] ? @"PASS" : @"OBSERVE", @"AV-11-notification",
		[presenter eventCount] ? @"presenter observed upload/content state activity" : @"no presenter activity observed");
	[uploadError release];

	NSData *first = UniquePatternData(2 * 1024 * 1024, 0xD1);
	NSData *second = UniquePatternData(2 * 1024 * 1024, 0xE1);
	BOOL wroteFirst = CoordinatedWrite(url, first, &error);
	NSFileVersion *firstVersion = wroteFirst ? [NSFileVersion currentVersionOfItemAtURL:url] : nil;
	BOOL wroteSecond = wroteFirst && CoordinatedWrite(url, second, &error);
	NSFileVersion *secondVersion = wroteSecond ? [NSFileVersion currentVersionOfItemAtURL:url] : nil;
	NSData *secondReadBack = wroteSecond ? CoordinatedRead(url, &error) : nil;
	BOOL staleRejected = wroteSecond && [secondReadBack isEqual:second] && ![secondReadBack isEqual:first] &&
		(!SameVersion(firstVersion, secondVersion) || ![first isEqual:second]);
	Report(staleRejected ? @"PASS" : @"FAIL", @"AV-11-stale",
		staleRejected ? @"a later replacement cannot satisfy the earlier exact-byte/version receipt" :
		[NSString stringWithFormat:@"error=%@", ErrorCode(error)]);

	[NSFileCoordinator removeFilePresenter:presenter];
	[[presenter presentedItemOperationQueue] waitUntilAllOperationsAreFinished];
	if (!CoordinatedDelete(sessionURL, &error))
		ReportError(@"FAIL", @"CLEANUP", error);
	else
		Report(@"PASS", @"CLEANUP", @"legacy-upload test subtree removed");
	return failures == 0 ? 0 : 1;
}

static BOOL TestBatchRead(NSURL *selectedURL, NSData *expectedData, NSURL *siblingURL, NSTimeInterval timeout) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block NSData *readData = nil;
	__block NSError *readError = nil;
	__block NSUInteger completionCalls = 0;
	NSError *prepareError = nil;
	[coordinator prepareForReadingItemsAtURLs:[NSArray arrayWithObject:selectedURL] options:0
		writingItemsAtURLs:[NSArray array] options:0 error:&prepareError byAccessor:^(void (^completionHandler)(void)) {
			readData = [CoordinatedRead(selectedURL, &readError) retain];
			completionCalls++;
			completionHandler();
		}];
	BOOL selectedCurrent = WaitUntilCurrent(selectedURL, timeout);
	BOOL siblingStillEvicted = IsDownloadStatus(siblingURL, NSURLUbiquitousItemDownloadingStatusNotDownloaded);
	BOOL valid = !prepareError && !readError && completionCalls == 1 && selectedCurrent && siblingStillEvicted && [readData isEqual:expectedData];
	[readData release];
	return valid;
}

static BOOL ProviderIdentitiesEqual(NSDictionary *first, NSDictionary *second) {
	return first && second &&
		[(NSObject *)[first objectForKey:@"item"] isEqual:[second objectForKey:@"item"]] &&
		[(NSObject *)[first objectForKey:@"domain"] isEqual:[second objectForKey:@"domain"]];
}

static BOOL DescriptorMatchesURL(int fileDescriptor, NSURL *url) {
	struct stat descriptorStatus = { 0 }, URLStatus = { 0 };
	const char *path = [url fileSystemRepresentation];
	return fileDescriptor >= 0 && path && fstat(fileDescriptor, &descriptorStatus) == 0 &&
		stat(path, &URLStatus) == 0 && descriptorStatus.st_dev == URLStatus.st_dev &&
		descriptorStatus.st_ino == URLStatus.st_ino;
}

static void RemoveContractItemIfPresent(NSURL *url) {
	if ([[NSFileManager defaultManager] fileExistsAtPath:[url path]])
		CoordinatedDelete(url, NULL);
}

static NSTask *StartMarkedRootMove(NSURL *sourceURL, NSURL *destinationURL,
	NSURL *markerURL, NSTimeInterval timeout, BOOL *outWasPending) {
	RemoveContractItemIfPresent(markerURL);
	NSTask *task = LaunchChild([NSArray arrayWithObjects:@"child-move-root-marked",
		[sourceURL path], [destinationURL path], [markerURL path], nil]);
	if (!task)
		return nil;
	BOOL marked = WaitFor(MIN(timeout, 15.0), ^BOOL{
		return [[NSFileManager defaultManager] fileExistsAtPath:[markerURL path]];
	});
	if (!marked) {
		if ([task isRunning])
			[task terminate];
		WaitFor(5.0, ^BOOL{ return ![task isRunning]; });
		return nil;
	}
	[NSThread sleepForTimeInterval:0.1];
	if (outWasPending)
		*outWasPending = [task isRunning];
	return task;
}

static BOOL FinishMarkedRootMove(NSTask *task, NSURL *markerURL,
	NVContractPresenter *presenter, NSUInteger priorMoveCount, NSTimeInterval timeout) {
	BOOL completed = task && WaitFor(timeout, ^BOOL{ return ![task isRunning]; });
	if (task && !completed && [task isRunning]) {
		[task terminate];
		WaitFor(5.0, ^BOOL{ return ![task isRunning]; });
	}
	BOOL callback = completed && WaitFor(MIN(timeout, 15.0), ^BOOL{
		return [presenter rootMoveCount] > priorMoveCount;
	});
	RemoveContractItemIfPresent(markerURL);
	return completed && [task terminationStatus] == 0 && callback;
}

static BOOL MoveRootAndWait(NSURL *sourceURL, NSURL *destinationURL,
	NVContractPresenter *presenter, NSTimeInterval timeout) {
	NSUInteger priorMoveCount = [presenter rootMoveCount];
	int status = RunChild([NSArray arrayWithObjects:@"child-move-root",
		[sourceURL path], [destinationURL path], nil]);
	return status == 0 && WaitFor(MIN(timeout, 15.0), ^BOOL{
		return [presenter rootMoveCount] > priorMoveCount;
	});
}

static BOOL MovedRootIdentityMatches(int rootDescriptor, NSDictionary *providerIdentity,
	NSURL *movedURL, NSTimeInterval timeout) {
	return DescriptorMatchesURL(rootDescriptor, movedURL) &&
		(!providerIdentity || ProviderIdentitiesEqual(providerIdentity,
			CopyProviderIdentity(movedURL, timeout, NULL)));
}

static BOOL IsFeatureUnsupportedError(NSError *error) {
	return [[error domain] isEqualToString:NSCocoaErrorDomain] &&
		[error code] == NSFeatureUnsupportedError;
}

static void TestPathIndependentProviderOperations(NSURL *rootURL, BOOL required,
	NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *firstRoot = [rootURL URLByAppendingPathComponent:@"nv-api-contract-path-a" isDirectory:YES];
	NSURL *secondRoot = [rootURL URLByAppendingPathComponent:@"nv-api-contract-path-b" isDirectory:YES];
	NSURL *markerURL = [rootURL URLByAppendingPathComponent:@".nv-api-contract-path-move-marker"];
	RemoveContractItemIfPresent(firstRoot);
	RemoveContractItemIfPresent(secondRoot);
	RemoveContractItemIfPresent(markerURL);

	NSData *noteData = UniquePatternData(65536, 0x21);
	NSData *batchData = UniquePatternData(1024 * 1024, 0x31);
	NSData *downloadData = UniquePatternData(8 * 1024 * 1024, 0x41);
	NSData *checkpointData = UniquePatternData(256 * 1024, 0x51);
	NSError *error = nil;
	BOOL setup = CoordinatedCreateDirectory(firstRoot, &error);
	NSDictionary *items = [NSDictionary dictionaryWithObjectsAndKeys:
		noteData, @"note.txt", batchData, @"batch.bin", downloadData, @"download.bin",
		checkpointData, @"checkpoint.bin", nil];
	for (NSString *name in items) {
		NSURL *url = [firstRoot URLByAppendingPathComponent:name];
		if (setup && !CoordinatedWrite(url, [items objectForKey:name], &error))
			setup = NO;
	}
	BOOL ubiquitous = [manager isUbiquitousItemAtURL:firstRoot];
	if (setup && ubiquitous) {
		for (NSString *name in items) {
			if (!WaitUntilUploaded([firstRoot URLByAppendingPathComponent:name], timeout)) {
				setup = NO;
				break;
			}
		}
	}
	if (!setup) {
		ReportError(@"FAIL", @"AV-08-path-setup", error);
		RemoveContractItemIfPresent(firstRoot);
		RemoveContractItemIfPresent(secondRoot);
		return;
	}

	int rootDescriptor = open([firstRoot fileSystemRepresentation],
		O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	NSURL *rootReference = [[firstRoot fileReferenceURL] retain];
	NSURL *noteReference = [[[firstRoot URLByAppendingPathComponent:@"note.txt"] fileReferenceURL] retain];
	NSData *rootBookmark = [[firstRoot bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
		relativeToURL:nil error:&error] retain];
	NSDictionary *rootProviderIdentity = [CopyProviderIdentity(firstRoot, timeout, &error) retain];
	NSDictionary *noteProviderIdentity = [CopyProviderIdentity(
		[firstRoot URLByAppendingPathComponent:@"note.txt"], timeout, &error) retain];
	NSFileVersion *initialVersion = [NSFileVersion currentVersionOfItemAtURL:
		[firstRoot URLByAppendingPathComponent:@"note.txt"]];
	id initialVersionID = [(NSObject *)[initialVersion persistentIdentifier] retain];
	NVContractPresenter *presenter = [[[NVContractPresenter alloc] initWithURL:firstRoot] autorelease];
	[NSFileCoordinator addFilePresenter:presenter];

	BOOL idleMoved = MoveRootAndWait(firstRoot, secondRoot, presenter, timeout);
	BOOL bookmarkStale = NO;
	NSURL *resolvedBookmark = rootBookmark ? [NSURL URLByResolvingBookmarkData:rootBookmark
		options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&bookmarkStale
		error:&error] : nil;
	BOOL idleFilesystemIdentity = idleMoved && rootDescriptor >= 0 &&
		DescriptorMatchesURL(rootDescriptor, secondRoot) &&
		DescriptorMatchesURL(rootDescriptor, rootReference) &&
		DescriptorMatchesURL(rootDescriptor, resolvedBookmark);
	BOOL providerIdentityMatches = ProviderIdentitiesEqual(rootProviderIdentity,
		CopyProviderIdentity(secondRoot, timeout, NULL)) &&
		ProviderIdentitiesEqual(noteProviderIdentity, CopyProviderIdentity(
			[secondRoot URLByAppendingPathComponent:@"note.txt"], timeout, NULL));
	NSString *identityKind = idleFilesystemIdentity && providerIdentityMatches ? @"PASS" :
		(idleFilesystemIdentity && !required ? @"OBSERVE" : @"FAIL");
	Report(identityKind, @"AV-08-provider-identity",
		idleFilesystemIdentity && providerIdentityMatches ?
		@"descriptor, file reference, bookmark, item identity, and domain identity survived root rename" :
		[NSString stringWithFormat:@"moved=%d descriptor=%d bookmark-stale=%d error=%@",
			idleMoved, rootDescriptor >= 0, bookmarkStale, ErrorCode(error)]);

	NSDictionary *movedCatalog = idleMoved ? CoordinatedCatalog([presenter currentURL], &error) : nil;
	NSData *movedRead = idleMoved ? CoordinatedRead(noteReference, &error) : nil;
	NSDictionary *promised = idleMoved ? CoordinatedPromisedMetadata(noteReference,
		[NSArray arrayWithObjects:NSURLFileResourceIdentifierKey, NSURLIsUbiquitousItemKey, nil], &error) : nil;
	NSFileVersion *movedVersion = idleMoved ? [NSFileVersion currentVersionOfItemAtURL:noteReference] : nil;
	BOOL postMoveAccess = [movedCatalog count] == [items count] && [movedRead isEqual:noteData] && promised &&
		initialVersionID && [(NSObject *)[movedVersion persistentIdentifier] isEqual:initialVersionID];
	Report(postMoveAccess ? @"PASS" : @"FAIL", @"AV-08-post-move-access",
		postMoveAccess ? @"catalog, promised metadata, coordinated read, and current version used retained references after rename" :
		[NSString stringWithFormat:@"catalog=%lu read=%d metadata=%d version=%d error=%@",
			(unsigned long)[movedCatalog count], [movedRead isEqual:noteData], promised != nil,
			initialVersionID && [(NSObject *)[movedVersion persistentIdentifier] isEqual:initialVersionID], ErrorCode(error)]);

	NSUInteger priorMoveCount = [presenter rootMoveCount];
	NSFileAccessIntent *readIntent = [NSFileAccessIntent readingIntentWithURL:
		[[secondRoot URLByAppendingPathComponent:@"note.txt"] fileReferenceURL] options:0];
	NSFileCoordinator *asyncCoordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:presenter] autorelease];
	NSOperationQueue *asyncQueue = [[[NSOperationQueue alloc] init] autorelease];
	[asyncQueue setMaxConcurrentOperationCount:1];
	__block NSTask *asyncMoveTask = nil;
	__block BOOL asyncMoveWasPending = NO;
	__block NSData *asyncRead = nil;
	__block NSError *asyncError = nil;
	dispatch_semaphore_t asyncDone = dispatch_semaphore_create(0);
	[asyncCoordinator coordinateAccessWithIntents:[NSArray arrayWithObject:readIntent] queue:asyncQueue
		byAccessor:^(NSError *coordinationError) {
			if (coordinationError)
				asyncError = [coordinationError retain];
			else {
				asyncMoveTask = [StartMarkedRootMove(secondRoot, firstRoot, markerURL, timeout,
					&asyncMoveWasPending) retain];
				asyncRead = [[NSData alloc] initWithContentsOfURL:[readIntent URL]
					options:0 error:&asyncError];
				[asyncError retain];
			}
			dispatch_semaphore_signal(asyncDone);
		}];
	BOOL asyncReturned = WaitSemaphore(asyncDone, timeout);
	BOOL asyncMoved = FinishMarkedRootMove(asyncMoveTask, markerURL, presenter, priorMoveCount, timeout);
	BOOL asyncValid = asyncReturned && asyncMoved && [asyncRead isEqual:noteData] &&
		MovedRootIdentityMatches(rootDescriptor, rootProviderIdentity, firstRoot, timeout);
	Report(asyncValid ? @"PASS" : @"FAIL", @"AV-08-async-read-during-move",
		asyncValid ? [NSString stringWithFormat:
			@"asynchronous coordinated read survived a root move initiated inside its accessor; move-waited=%d",
			asyncMoveWasPending] :
		[NSString stringWithFormat:@"accessor=%d moved=%d read=%d error=%@",
			asyncReturned, asyncMoved, [asyncRead isEqual:noteData], ErrorCode(asyncError)]);
	[asyncMoveTask release];
	[asyncRead release];
	[asyncError release];

	priorMoveCount = [presenter rootMoveCount];
	__block NSTask *catalogMoveTask = nil;
	__block BOOL catalogMoveWasPending = NO;
	error = nil;
	NSDictionary *inFlightCatalog = CoordinatedCatalogPerformingAccessorAction(
		[firstRoot fileReferenceURL], ^{
			catalogMoveTask = [StartMarkedRootMove(firstRoot, secondRoot, markerURL, timeout,
				&catalogMoveWasPending) retain];
		}, &error);
	BOOL catalogMoved = FinishMarkedRootMove(catalogMoveTask, markerURL, presenter, priorMoveCount, timeout);
	BOOL catalogRestored = catalogMoved && MoveRootAndWait(secondRoot, firstRoot, presenter, timeout);
	BOOL catalogValid = [inFlightCatalog count] == [items count] && catalogMoved && catalogRestored &&
		MovedRootIdentityMatches(rootDescriptor, rootProviderIdentity, firstRoot, timeout);
	Report(catalogValid ? @"PASS" : @"FAIL", @"AV-08-catalog-during-move",
		catalogValid ? [NSString stringWithFormat:
			@"shallow catalog survived a root move initiated inside its accessor; move-waited=%d",
			catalogMoveWasPending] :
		[NSString stringWithFormat:@"catalog=%lu moved=%d restored=%d error=%@",
			(unsigned long)[inFlightCatalog count], catalogMoved, catalogRestored, ErrorCode(error)]);
	[catalogMoveTask release];

	priorMoveCount = [presenter rootMoveCount];
	NSURL *batchReference = [[[[firstRoot URLByAppendingPathComponent:@"batch.bin"] fileReferenceURL] retain] autorelease];
	NSFileCoordinator *batchCoordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:presenter] autorelease];
	__block NSTask *batchMoveTask = nil;
	__block BOOL batchMoveWasPending = NO;
	__block NSData *batchRead = nil;
	__block NSError *batchReadError = nil;
	__block NSUInteger batchCompletionCalls = 0;
	NSError *batchPrepareError = nil;
	[batchCoordinator prepareForReadingItemsAtURLs:[NSArray arrayWithObject:batchReference] options:0
		writingItemsAtURLs:[NSArray array] options:0 error:&batchPrepareError
		byAccessor:^(void (^completionHandler)(void)) {
			batchMoveTask = [StartMarkedRootMove(firstRoot, secondRoot, markerURL, timeout,
				&batchMoveWasPending) retain];
			batchRead = [CoordinatedRead(batchReference, &batchReadError) retain];
			[batchReadError retain];
			batchCompletionCalls++;
			completionHandler();
		}];
	BOOL batchMoved = FinishMarkedRootMove(batchMoveTask, markerURL, presenter, priorMoveCount, timeout);
	BOOL batchValid = !batchPrepareError && !batchReadError && batchCompletionCalls == 1 && batchMoved &&
		[batchRead isEqual:batchData] && MovedRootIdentityMatches(rootDescriptor,
			rootProviderIdentity, secondRoot, timeout);
	Report(batchValid ? @"PASS" : @"FAIL", @"AV-08-batch-during-move",
		batchValid ? [NSString stringWithFormat:
			@"batch preparation and nested read survived a root move initiated inside its accessor; move-waited=%d",
			batchMoveWasPending] :
		[NSString stringWithFormat:@"completion=%lu moved=%d read=%d error=%@",
			(unsigned long)batchCompletionCalls, batchMoved, [batchRead isEqual:batchData],
			ErrorCode(batchPrepareError ?: batchReadError)]);
	[batchMoveTask release];
	[batchRead release];
	[batchReadError release];

	priorMoveCount = [presenter rootMoveCount];
	NSURL *replaceReference = [[[secondRoot URLByAppendingPathComponent:@"note.txt"] fileReferenceURL] retain];
	NSDictionary *replaceIdentity = [CopyProviderIdentity(replaceReference, timeout, NULL) retain];
	NSData *replacementData = UniquePatternData(131072, 0x61);
	__block NSTask *replaceMoveTask = nil;
	__block BOOL replaceMoveWasPending = NO;
	error = nil;
	NSURL *replacementResult = CoordinatedSafeReplacePerformingAccessorAction(replaceReference,
		replacementData, ^{
			replaceMoveTask = [StartMarkedRootMove(secondRoot, firstRoot, markerURL, timeout,
				&replaceMoveWasPending) retain];
		}, &error);
	BOOL replacementMoved = FinishMarkedRootMove(replaceMoveTask, markerURL, presenter, priorMoveCount, timeout);
	NSURL *replacedURL = [firstRoot URLByAppendingPathComponent:@"note.txt"];
	BOOL replacementValid = replacementResult && replacementMoved &&
		[CoordinatedRead(replacedURL, NULL) isEqual:replacementData] &&
		(!replaceIdentity || ProviderIdentitiesEqual(replaceIdentity,
			CopyProviderIdentity(replacedURL, timeout, NULL))) &&
		MovedRootIdentityMatches(rootDescriptor, rootProviderIdentity, firstRoot, timeout);
	Report(replacementValid ? @"PASS" : @"FAIL", @"AV-08-safe-replace-during-move",
		replacementValid ? [NSString stringWithFormat:
			@"Foundation replacement survived a root move initiated inside its accessor; move-waited=%d",
			replaceMoveWasPending] :
		[NSString stringWithFormat:@"replaced=%d moved=%d exact=%d error=%@",
			replacementResult != nil, replacementMoved,
			[CoordinatedRead(replacedURL, NULL) isEqual:replacementData], ErrorCode(error)]);
	[replaceMoveTask release];
	[replaceReference release];
	[replaceIdentity release];

	NSURL *downloadURL = [firstRoot URLByAppendingPathComponent:@"download.bin"];
	BOOL materializationReady = ubiquitous && WaitUntilUploaded(downloadURL, timeout) &&
		[manager evictUbiquitousItemAtURL:downloadURL error:&error] &&
		WaitUntilNotDownloaded(downloadURL, timeout);
	NSURL *downloadReference = materializationReady ? [downloadURL fileReferenceURL] : nil;
	BOOL downloadRequested = downloadReference &&
		[manager startDownloadingUbiquitousItemAtURL:downloadReference error:&error];
	BOOL currentBeforeMove = downloadRequested && WaitFor(0.05, ^BOOL{
		return IsDownloadStatus(downloadReference, NSURLUbiquitousItemDownloadingStatusCurrent);
	});
	BOOL downloadMoved = downloadRequested && MoveRootAndWait(firstRoot, secondRoot, presenter, timeout);
	NSURL *movedDownloadURL = [secondRoot URLByAppendingPathComponent:@"download.bin"];
	BOOL downloadedAfterMove = downloadMoved && WaitUntilCurrent(movedDownloadURL, timeout) &&
		[CoordinatedRead(movedDownloadURL, &error) isEqual:downloadData];
	NSString *downloadKind = materializationReady && downloadRequested && downloadMoved && downloadedAfterMove ?
		(currentBeforeMove ? @"OBSERVE" : @"PASS") : @"FAIL";
	Report(downloadKind, @"AV-08-materialization-across-move",
		downloadedAfterMove ? [NSString stringWithFormat:
			@"download requested from evicted state and completed after move; already-current-before-move=%d",
			currentBeforeMove] : [NSString stringWithFormat:
			@"ready=%d requested=%d moved=%d exact=%d error=%@", materializationReady,
			downloadRequested, downloadMoved, downloadedAfterMove, ErrorCode(error)]);

	NSURL *versionURL = [secondRoot URLByAppendingPathComponent:@"note.txt"];
	NSURL *versionReference = [versionURL fileReferenceURL];
	NSFileVersion *versionBeforeMove = [NSFileVersion currentVersionOfItemAtURL:versionReference];
	id versionBeforeMoveID = [(NSObject *)[versionBeforeMove persistentIdentifier] retain];
	__block NSArray *nonlocalVersions = nil;
	__block NSError *nonlocalError = nil;
	__block BOOL nonlocalCompleted = NO;
	dispatch_semaphore_t nonlocalDone = dispatch_semaphore_create(0);
	NSFileCoordinator *versionCoordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:presenter] autorelease];
	NSError *versionCoordinationError = nil;
	[versionCoordinator coordinateReadingItemAtURL:versionReference options:0 error:&versionCoordinationError
		byAccessor:^(NSURL *newURL) {
			[NSFileVersion getNonlocalVersionsOfItemAtURL:newURL completionHandler:
				^(NSArray *versions, NSError *requestError) {
					nonlocalVersions = [versions retain];
					nonlocalError = [requestError retain];
					nonlocalCompleted = YES;
					dispatch_semaphore_signal(nonlocalDone);
				}];
		}];
	BOOL nonlocalWasPending = !nonlocalCompleted;
	BOOL versionMoved = MoveRootAndWait(secondRoot, firstRoot, presenter, timeout);
	BOOL nonlocalReturned = nonlocalCompleted || WaitSemaphore(nonlocalDone, timeout);
	NSFileVersion *versionAfterMove = [NSFileVersion currentVersionOfItemAtURL:
		[firstRoot URLByAppendingPathComponent:@"note.txt"]];
	BOOL localVersionStable = versionMoved && versionBeforeMoveID &&
		[(NSObject *)[versionAfterMove persistentIdentifier] isEqual:versionBeforeMoveID];
	Report(localVersionStable ? @"PASS" : @"FAIL", @"AV-08-version-identity",
		localVersionStable ? @"current-version identity survived the root move" :
		[NSString stringWithFormat:@"moved=%d error=%@", versionMoved, ErrorCode(versionCoordinationError)]);
	if (nonlocalReturned && !nonlocalError)
		Report(@"PASS", @"AV-08-nonlocal-versions-across-move",
			[NSString stringWithFormat:@"request completed across move; pending-at-move=%d count=%lu",
				nonlocalWasPending, (unsigned long)[nonlocalVersions count]]);
	else if (IsFeatureUnsupportedError(nonlocalError))
		Report(@"OBSERVE", @"AV-08-nonlocal-versions-across-move",
			@"provider reports the documented stable featureUnsupported fallback");
	else
		Report(required ? @"FAIL" : @"OBSERVE", @"AV-08-nonlocal-versions-across-move",
			[NSString stringWithFormat:@"returned=%d pending-at-move=%d error=%@",
				nonlocalReturned, nonlocalWasPending, ErrorCode(nonlocalError ?: versionCoordinationError)]);
	[versionBeforeMoveID release];
	[nonlocalVersions release];
	[nonlocalError release];

	NSURL *currentRoot = versionMoved ? firstRoot : secondRoot;
	if (@available(macOS 26.0, *)) {
		NSURL *checkpointURL = [currentRoot URLByAppendingPathComponent:@"checkpoint.bin"];
		NSNumber *controlNumber = ResourceValue(checkpointURL,
			NSURLUbiquitousItemSupportedSyncControlsKey, NULL);
		NSFileManagerSupportedSyncControls controls = [controlNumber unsignedIntegerValue];
		if (!(controls & NSFileManagerSupportedSyncControlsPauseSync))
			Report(@"SKIP", @"AV-08-sync-controls-across-move",
				@"pause is not advertised; ordinary synchronization remains the path-independent fallback");
		else {
			NSError *pauseError = WaitUntilUploaded(checkpointURL, timeout) ?
				PauseSyncWhenStable([checkpointURL fileReferenceURL], timeout) :
				[NSError errorWithDomain:@"NVAPIContractTest" code:ETIMEDOUT userInfo:nil];
			if (pauseError)
				Report(@"OBSERVE", @"AV-08-sync-controls-across-move",
					[NSString stringWithFormat:@"pause failed before acquisition; error=%@", ErrorCode(pauseError)]);
			else {
				NSData *syncReplacement = UniquePatternData(512 * 1024, 0x71);
				NSURL *pausedReference = [checkpointURL fileReferenceURL];
				NSDictionary *syncIdentity = [CopyProviderIdentity(pausedReference, timeout, NULL) retain];
				NSError *replaceError = nil;
				NSURL *syncResult = CoordinatedSafeReplace(pausedReference, syncReplacement, &replaceError);
				NSFileVersion *installedVersion = syncResult ?
					[NSFileVersion currentVersionOfItemAtURL:syncResult] : nil;
				NSURL *otherRoot = [currentRoot isEqual:firstRoot] ? secondRoot : firstRoot;
				BOOL syncMoved = syncResult && MoveRootAndWait(currentRoot, otherRoot, presenter, timeout);
				NSURL *movedCheckpointURL = [otherRoot URLByAppendingPathComponent:@"checkpoint.bin"];
				NSURL *movedCheckpointReference = [movedCheckpointURL fileReferenceURL];
				NSNumber *pausedAfterMove = ResourceValue(movedCheckpointReference,
					NSURLUbiquitousItemIsSyncPausedKey, NULL);
				NSError *uploadError = nil;
				NSFileVersion *uploadedVersion = nil;
				BOOL exactUploadSupported =
					(controls & NSFileManagerSupportedSyncControlsFailUploadOnConflict) != 0;
				if (syncMoved && exactUploadSupported)
					uploadedVersion = WaitForAsyncVersion(timeout,
						^(void (^completion)(NSFileVersion *, NSError *)) {
							[manager uploadLocalVersionOfUbiquitousItemAtURL:movedCheckpointReference
								withConflictResolutionPolicy:NSFileManagerUploadConflictPolicyFailOnConflict
								completionHandler:completion];
						}, &uploadError);
				NSURL *resumeURL = syncMoved ? movedCheckpointReference : (syncResult ?: pausedReference);
				NSError *resumeError = WaitForAsyncError(timeout, ^(void (^completion)(NSError *)) {
					[manager resumeSyncForUbiquitousItemAtURL:resumeURL
						withBehavior:NSFileManagerResumeSyncBehaviorPreserveLocalChanges
						completionHandler:completion];
				});
				BOOL exactVersion = !exactUploadSupported || SameVersion(installedVersion, uploadedVersion);
				BOOL syncValid = syncResult && syncMoved && [pausedAfterMove boolValue] &&
					(!syncIdentity || ProviderIdentitiesEqual(syncIdentity,
						CopyProviderIdentity(movedCheckpointReference, timeout, NULL))) &&
					MovedRootIdentityMatches(rootDescriptor, rootProviderIdentity, otherRoot, timeout) &&
					[CoordinatedRead(movedCheckpointReference, NULL) isEqual:syncReplacement] &&
					exactVersion && !uploadError && !resumeError &&
					WaitUntilUploaded(movedCheckpointReference, timeout);
				Report(syncValid ? @"PASS" : @"FAIL", @"AV-08-sync-controls-across-move",
					syncValid ? @"pause, Foundation replacement, root move, exact upload when available, and resume retained one item identity" :
					[NSString stringWithFormat:@"replaced=%d moved=%d paused=%d exact-version=%d upload-error=%@ resume-error=%@",
						syncResult != nil, syncMoved, [pausedAfterMove boolValue], exactVersion,
						ErrorCode(uploadError ?: replaceError), ErrorCode(resumeError)]);
				[syncIdentity release];
				if (syncMoved)
					currentRoot = otherRoot;
			}
		}
	} else
		Report(@"SKIP", @"AV-08-sync-controls-across-move", @"requires macOS 26 or later");

	[NSFileCoordinator removeFilePresenter:presenter];
	[[presenter presentedItemOperationQueue] waitUntilAllOperationsAreFinished];
	if (rootDescriptor >= 0)
		close(rootDescriptor);
	RemoveContractItemIfPresent(firstRoot);
	RemoveContractItemIfPresent(secondRoot);
	RemoveContractItemIfPresent(markerURL);
	[rootReference release];
	[noteReference release];
	[rootBookmark release];
	[rootProviderIdentity release];
	[noteProviderIdentity release];
	[initialVersionID release];
}

static void TestCurrentVersionSnapshotContract(NSURL *url, BOOL required,
	NSTimeInterval timeout) {
	NSError *error = nil;
	NSDictionary *before = CoordinatedCurrentSnapshot(url, &error);
	NSData *bytes = [before objectForKey:@"bytes"];
	id version = [before objectForKey:@"version"];
	BOOL coherent = bytes && version;
	Report(coherent ? @"PASS" : (required ? @"FAIL" : @"OBSERVE"),
		@"AV-02-current-snapshot", coherent ?
		@"one coordinated accessor returned exact bytes and matching local-version evidence" :
		[NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
	if (!coherent)
		return;
	NSFileVersion *roundTrip = CoordinatedVersionForIdentifier(url, version, &error);
	BOOL identifierRoundTrip = roundTrip &&
		[(NSObject *)[roundTrip persistentIdentifier] isEqual:version];
	Report(identifierRoundTrip ? @"PASS" : (required ? @"FAIL" : @"OBSERVE"),
		@"AV-05-persistent-id-roundtrip", identifierRoundTrip ?
		@"the current version was recreated from its documented persistent identifier" :
		@"the current version could not be recreated from its persistent identifier");

	BOOL replaced = CoordinatedSafeReplace([[FreshURL(url) absoluteURL] fileReferenceURL],
		bytes, &error) != nil;
	__block BOOL exactBytes = NO;
	__block BOOL changedVersion = NO;
	__block BOOL changedFilesystem = NO;
	__block BOOL changedFileID = NO;
	__block BOOL changedGeneration = NO;
	__block BOOL changedDocumentID = NO;
	BOOL observed = replaced && WaitFor(MIN(timeout, 60.0), ^BOOL{
		NSDictionary *after = CoordinatedCurrentSnapshot(url, NULL);
		NSDictionary *beforeFilesystem = [before objectForKey:@"filesystem"];
		NSDictionary *afterFilesystem = [after objectForKey:@"filesystem"];
		exactBytes = [[after objectForKey:@"bytes"] isEqual:bytes];
		changedVersion = [after objectForKey:@"version"] &&
			![(NSObject *)[after objectForKey:@"version"] isEqual:version];
		changedFilesystem = afterFilesystem && ![afterFilesystem isEqual:beforeFilesystem];
		changedFileID = [afterFilesystem objectForKey:@"fileID"] &&
			[beforeFilesystem objectForKey:@"fileID"] &&
			![[afterFilesystem objectForKey:@"fileID"] isEqual:
				[beforeFilesystem objectForKey:@"fileID"]];
		changedGeneration = [afterFilesystem objectForKey:@"generation"] &&
			[beforeFilesystem objectForKey:@"generation"] &&
			![[afterFilesystem objectForKey:@"generation"] isEqual:
				[beforeFilesystem objectForKey:@"generation"]];
		changedDocumentID = [afterFilesystem objectForKey:@"documentID"] &&
			[beforeFilesystem objectForKey:@"documentID"] &&
			![[afterFilesystem objectForKey:@"documentID"] isEqual:
				[beforeFilesystem objectForKey:@"documentID"]];
		return exactBytes;
	});
	Report(observed ? @"OBSERVE" : (required ? @"FAIL" : @"OBSERVE"),
		@"AV-02-same-bytes-replacement", observed ?
		[NSString stringWithFormat:
			@"same bytes remained coherent; NSFileVersion-changed=%d filesystem-witness-changed=%d file-id=%d generation=%d document-id=%d",
			changedVersion, changedFilesystem, changedFileID, changedGeneration,
			changedDocumentID] :
		[NSString stringWithFormat:@"replaced=%d exact-bytes=%d changed-version=%d error=%@",
			replaced, exactBytes, changedVersion, ErrorCode(error)]);

	NSData *different = UniquePatternData([bytes length] + 1, 0xB1);
	BOOL changed = observed && CoordinatedSafeReplace(
		[[FreshURL(url) absoluteURL] fileReferenceURL], different, &error) != nil;
	NSDictionary *changedSnapshot = changed ? CoordinatedCurrentSnapshot(url, &error) : nil;
	BOOL mismatchVisible = changedSnapshot &&
		[[changedSnapshot objectForKey:@"bytes"] isEqual:different] &&
		![[changedSnapshot objectForKey:@"bytes"] isEqual:bytes];
	Report(mismatchVisible ? @"PASS" : (required ? @"FAIL" : @"OBSERVE"),
		@"AV-02-current-byte-mismatch", mismatchVisible ?
		@"a different-byte replacement was returned as one coherent current snapshot" :
		[NSString stringWithFormat:@"changed=%d error=%@", changed, ErrorCode(error)]);
}

static int RunFoundationReplacementContracts(NSURL *rootURL, BOOL required,
	NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *sessionURL = [rootURL URLByAppendingPathComponent:
		@"nv-api-contract-foundation" isDirectory:YES];
	[manager removeItemAtURL:sessionURL error:NULL];
	NSError *error = nil;
	NSURL *url = [sessionURL URLByAppendingPathComponent:@"replacement.bin"];
	NSData *first = UniquePatternData(1024 * 1024, 0x41);
	NSData *second = UniquePatternData(1024 * 1024 + 17, 0x61);
	BOOL providerManaged = [manager isUbiquitousItemAtURL:rootURL];
	BOOL ready = providerManaged ?
		(CoordinatedCreateDirectory(sessionURL, &error) && CoordinatedWrite(url, first, &error)) :
		([manager createDirectoryAtURL:sessionURL withIntermediateDirectories:NO
			attributes:nil error:&error] &&
		 [first writeToURL:url options:NSDataWritingAtomic error:&error]);
	if (ready && [manager isUbiquitousItemAtURL:url])
		ready = WaitUntilUploaded(url, timeout);
	if (!ready) {
		ReportError(@"FAIL", @"FOUNDATION-SETUP", error);
		[manager removeItemAtURL:sessionURL error:NULL];
		return 1;
	}
	TestCurrentVersionSnapshotContract(url, required, timeout);
	TestFileIdentityLifecycle(sessionURL, required, timeout);

	int rootDescriptor = open([sessionURL fileSystemRepresentation],
		O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	NSURL *oldReference = [[[FreshURL(url) absoluteURL] fileReferenceURL] retain];
	NSDictionary *identityBefore = [CopyProviderIdentity(url, timeout, NULL) retain];
	NSURL *dualResult = CoordinatedSafeReplace([[FreshURL(url) absoluteURL] fileReferenceURL], second, &error);
	BOOL dualCoordination = dualResult != nil;
	Report(dualCoordination ? @"PASS" : (required ? @"FAIL" : @"OBSERVE"),
		@"FOUNDATION-dual-coordination", dualCoordination ?
		@"destination and replacement-stage coordination admitted Foundation replacement" :
		[NSString stringWithFormat:@"error=%@", ErrorCode(error)]);
	BOOL reset = dualResult && CoordinatedSafeReplace(
		[[FreshURL(url) absoluteURL] fileReferenceURL], first, &error);
	NSData *xattr = [@"nv-contract" dataUsingEncoding:NSUTF8StringEncoding];
	BOOL xattrSet = reset && setxattr([url fileSystemRepresentation], "com.notational.contract",
		[xattr bytes], [xattr length], 0, XATTR_NOFOLLOW) == 0;
	if (xattrSet && providerManaged)
		WaitUntilUploaded(url, timeout);

	__block BOOL sawInvalidRead = NO;
	__block NSUInteger reads = 0;
	dispatch_group_t readers = dispatch_group_create();
	dispatch_queue_t readerQueue = dispatch_queue_create("com.notational.contract.reader",
		DISPATCH_QUEUE_SERIAL);
	dispatch_group_async(readers, readerQueue, ^{
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
		while ([deadline timeIntervalSinceNow] > 0.0) {
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSData *observed = [NSData dataWithContentsOfURL:url];
			if (!observed || (![observed isEqual:first] && ![observed isEqual:second]))
				sawInvalidRead = YES;
			reads++;
			[pool drain];
		}
	});
	[NSThread sleepForTimeInterval:0.05];
	BOOL replaced = reset;
	NSURL *resultURL = nil;
	if (replaced) {
		resultURL = CoordinatedSafeReplace([[FreshURL(url) absoluteURL] fileReferenceURL],
			second, &error);
		replaced = resultURL != nil;
	}
	dispatch_group_wait(readers, DISPATCH_TIME_FOREVER);
	BOOL exactFinal = replaced && [CoordinatedRead(url, &error) isEqual:second];
	Report(replaced && exactFinal && !sawInvalidRead && reads ? @"PASS" : @"FAIL",
		@"FOUNDATION-atomic-visibility", [NSString stringWithFormat:
			@"replaced=%d exact=%d reads=%lu invalid=%d error=%@", replaced, exactFinal,
			(unsigned long)reads, sawInvalidRead, ErrorCode(error)]);

	NSString *backupName = [NSString stringWithFormat:@".nv-contract-%@.backup",
		[[NSUUID UUID] UUIDString]];
	NSURL *backupURL = [sessionURL URLByAppendingPathComponent:backupName];
	NSData *third = UniquePatternData(512 * 1024 + 29, 0x81);
	NSURL *backupResult = exactFinal ? CoordinatedSafeReplaceWithBackup(
		[[FreshURL(url) absoluteURL] fileReferenceURL], third, backupName, &error) : nil;
	BOOL retainedBackup = backupResult && [CoordinatedRead(url, NULL) isEqual:third] &&
		[CoordinatedRead(backupURL, NULL) isEqual:second];
	Report(retainedBackup ? @"PASS" : @"FAIL", @"FOUNDATION-retained-backup",
		retainedBackup ? @"replacement retained the exact displaced bytes under the supplied unique leaf" :
		[NSString stringWithFormat:@"result=%d error=%@", backupResult != nil, ErrorCode(error)]);

	NSDictionary *identityAfter = backupResult ? CopyProviderIdentity(url, timeout, NULL) : nil;
	BOOL providerIdentity = identityBefore ? ProviderIdentitiesEqual(identityBefore, identityAfter) : !required;
	BOOL rootIdentity = DescriptorMatchesURL(rootDescriptor, sessionURL);
	NSString *identityKind = rootIdentity && providerIdentity ? @"PASS" :
		(required ? @"FAIL" : @"OBSERVE");
	Report(identityKind, @"FOUNDATION-identity", [NSString stringWithFormat:
		@"root=%d provider-before=%d provider-preserved=%d old-reference-reachable=%d",
		rootIdentity, identityBefore != nil, providerIdentity,
		[oldReference checkResourceIsReachableAndReturnError:NULL]]);
	NSData *xattrAfter = XAttrData(url, "com.notational.contract");
	Report(xattrSet && [xattrAfter isEqual:xattr] ? @"PASS" : @"OBSERVE",
		@"FOUNDATION-metadata", [NSString stringWithFormat:
			@"custom-xattr-set=%d preserved=%d", xattrSet, [xattrAfter isEqual:xattr]]);

	if (rootDescriptor >= 0)
		close(rootDescriptor);
	[oldReference release];
	[identityBefore release];
	[manager removeItemAtURL:sessionURL error:NULL];
	return failures == 0 ? 0 : 1;
}

static int ChildWALWrite(NSURL *directoryURL) {
	int directoryDescriptor = open([directoryURL fileSystemRepresentation],
		O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (directoryDescriptor < 0)
		return 2;
	int descriptor = openat(directoryDescriptor, "contract.wal",
		O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (descriptor < 0)
		return 3;
	const char header[] = "NVWAL\n";
	const char record[] = "record\n";
	BOOL durable = write(descriptor, header, sizeof(header) - 1) == sizeof(header) - 1 &&
		fsync(descriptor) == 0 && fsync(directoryDescriptor) == 0 &&
		write(descriptor, record, sizeof(record) - 1) == sizeof(record) - 1 &&
		fsync(descriptor) == 0;
	close(descriptor);
	close(directoryDescriptor);
	_exit(durable ? 0 : 4);
}

static int RunLocalWALContracts(void) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSError *error = nil;
	NSURL *applicationSupport = [manager URLForDirectory:NSApplicationSupportDirectory
		inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:&error];
	NSURL *recoveryJournals = [[applicationSupport URLByAppendingPathComponent:
		@"Notational Velocity" isDirectory:YES] URLByAppendingPathComponent:
		@"Recovery Journals" isDirectory:YES];
	BOOL exactLocation = applicationSupport &&
		[[recoveryJournals lastPathComponent] isEqualToString:@"Recovery Journals"] &&
		[[[recoveryJournals URLByDeletingLastPathComponent] lastPathComponent]
			isEqualToString:@"Notational Velocity"];
	Report(exactLocation ? @"PASS" : @"FAIL", @"AV-15-location",
		exactLocation ? @"user Application Support resolves the exact Recovery Journals child" :
		[NSString stringWithFormat:@"error=%@", ErrorCode(error)]);

	NSURL *sessionURL = [applicationSupport URLByAppendingPathComponent:
		[NSString stringWithFormat:@"Notational Velocity API Contract %@",
			[[NSUUID UUID] UUIDString]] isDirectory:YES];
	BOOL created = [manager createDirectoryAtURL:sessionURL withIntermediateDirectories:NO
		attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedShort:0700]
			forKey:NSFilePosixPermissions] error:&error];
	int childStatus = created ? RunChild([NSArray arrayWithObjects:@"child-wal-write",
		[sessionURL path], nil]) : -1;
	NSURL *walURL = [sessionURL URLByAppendingPathComponent:@"contract.wal"];
	NSData *expected = [@"NVWAL\nrecord\n" dataUsingEncoding:NSUTF8StringEncoding];
	struct stat status = { 0 };
	NSData *walData = [NSData dataWithContentsOfURL:walURL options:0 error:&error];
	BOOL stated = lstat([walURL fileSystemRepresentation], &status) == 0;
	BOOL exact = childStatus == 0 && [walData isEqual:expected] && stated &&
		(status.st_mode & 0777) == 0600;
	Report(exact ? @"PASS" : @"FAIL", @"AV-15-crash-boundary",
		[NSString stringWithFormat:@"child=%d exact=%d mode=%o error=%@", childStatus,
			exact, status.st_mode & 0777, ErrorCode(error)]);

	NSURL *targetURL = [sessionURL URLByAppendingPathComponent:@"target"];
	NSURL *linkURL = [sessionURL URLByAppendingPathComponent:@"malicious-link"];
	BOOL symlinkReady = RawWrite(targetURL, [@"target" dataUsingEncoding:NSUTF8StringEncoding], &error) &&
		symlink([[targetURL path] fileSystemRepresentation], [linkURL fileSystemRepresentation]) == 0;
	int linkDescriptor = symlinkReady ? open([linkURL fileSystemRepresentation],
		O_RDONLY | O_CLOEXEC | O_NOFOLLOW) : -1;
	BOOL symlinkRejected = linkDescriptor < 0 && errno == ELOOP;
	if (linkDescriptor >= 0)
		close(linkDescriptor);
	Report(symlinkRejected ? @"PASS" : @"FAIL", @"AV-15-symlink",
		symlinkRejected ? @"O_NOFOLLOW rejected the malicious WAL leaf" :
		[NSString stringWithFormat:@"ready=%d errno=%d", symlinkReady, errno]);

	int directoryDescriptor = open([sessionURL fileSystemRepresentation],
		O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	BOOL deleted = unlinkat(directoryDescriptor, "contract.wal", 0) == 0 &&
		fsync(directoryDescriptor) == 0;
	if (directoryDescriptor >= 0)
		close(directoryDescriptor);
	Report(deleted ? @"PASS" : @"FAIL", @"AV-15-delete-barrier",
		deleted ? @"WAL deletion and containing-directory barrier completed" :
		[NSString stringWithFormat:@"errno=%d", errno]);
	[manager removeItemAtURL:sessionURL error:NULL];
	return failures == 0 ? 0 : 1;
}

static int RunWALRebootPrepare(NSURL *directoryURL) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSError *error = nil;
	if ([manager fileExistsAtPath:[directoryURL path]] ||
		![manager createDirectoryAtURL:directoryURL withIntermediateDirectories:NO
			attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedShort:0700]
				forKey:NSFilePosixPermissions] error:&error]) {
		Report(@"FAIL", @"AV-15-reboot-prepare",
			[NSString stringWithFormat:@"test directory must be absent error=%@", ErrorCode(error)]);
		return 1;
	}
	int childStatus = RunChild([NSArray arrayWithObjects:@"child-wal-write",
		[directoryURL path], nil]);
	NSData *expected = [@"NVWAL\nrecord\n" dataUsingEncoding:NSUTF8StringEncoding];
	BOOL ready = childStatus == 0 && [[NSData dataWithContentsOfURL:
		[directoryURL URLByAppendingPathComponent:@"contract.wal"]] isEqual:expected];
	Report(ready ? @"READY" : @"FAIL", @"AV-15-reboot-prepare",
		ready ? @"durable WAL is ready; reboot before running wal-reboot-verify" :
		[NSString stringWithFormat:@"child=%d", childStatus]);
	return ready ? 0 : 1;
}

static int RunWALRebootVerify(NSURL *directoryURL) {
	NSURL *walURL = [directoryURL URLByAppendingPathComponent:@"contract.wal"];
	NSData *expected = [@"NVWAL\nrecord\n" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *actual = [NSData dataWithContentsOfURL:walURL];
	int directoryDescriptor = open([directoryURL fileSystemRepresentation],
		O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	BOOL exact = [actual isEqual:expected];
	BOOL deleted = exact && directoryDescriptor >= 0 &&
		unlinkat(directoryDescriptor, "contract.wal", 0) == 0 && fsync(directoryDescriptor) == 0;
	if (directoryDescriptor >= 0)
		close(directoryDescriptor);
	if (deleted)
		[[NSFileManager defaultManager] removeItemAtURL:directoryURL error:NULL];
	Report(exact && deleted ? @"PASS" : @"FAIL", @"AV-15-reboot-verify",
		[NSString stringWithFormat:@"exact=%d deleted=%d errno=%d", exact, deleted, errno]);
	return exact && deleted ? 0 : 1;
}

static int RunLocal(NSURL *rootURL, NSString *testPolicy, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	BOOL required = [testPolicy isEqualToString:@"required"] || [testPolicy isEqualToString:@"icloud"];
	BOOL rootIsDirectory = NO;
	if (![manager fileExistsAtPath:[rootURL path] isDirectory:&rootIsDirectory] || !rootIsDirectory) {
		Report(@"FAIL", @"SETUP", @"test root is unavailable");
		return 1;
	}

	BOOL ubiquitousByManager = [manager isUbiquitousItemAtURL:rootURL];
	NSNumber *ubiquitousValue = ResourceValue(rootURL, NSURLIsUbiquitousItemKey, NULL);
	if (required && ubiquitousByManager && [ubiquitousValue boolValue])
		Report(@"PASS", @"AV-01", @"root positively identified as ubiquitous");
	else if (required)
		Report(@"FAIL", @"AV-01", @"root was not positively identified as ubiquitous");
	else if (ubiquitousByManager)
		Report(@"PASS", @"AV-01", @"selected observational root exposes ubiquitous-item semantics");
	else
		Report(@"OBSERVE", @"AV-01", [NSString stringWithFormat:@"ubiquitous=%d", ubiquitousByManager]);

	NSURL *sessionURL = [rootURL URLByAppendingPathComponent:@"nv-api-contract-local" isDirectory:YES];
	NSError *error = nil;
	if (!CoordinatedCreateDirectory(sessionURL, &error)) {
		ReportError(@"FAIL", @"SETUP", error);
		return 1;
	}
	NVContractPresenter *presenter = [[[NVContractPresenter alloc] initWithURL:sessionURL] autorelease];
	[NSFileCoordinator addFilePresenter:presenter];

	NSData *downloadData = PatternData(1024 * 1024, 0x11);
	NSData *batchData = PatternData(1024 * 1024, 0x31);
	NSData *siblingData = PatternData(1024 * 1024, 0x51);
	NSDictionary *files = [NSDictionary dictionaryWithObjectsAndKeys:
		downloadData, @"download.bin", batchData, @"batch-selected.bin", siblingData, @"batch-sibling.bin",
		[@"base" dataUsingEncoding:NSUTF8StringEncoding], @"versioned.txt",
		PatternData(65536, 0x71), @"sync-control.bin", nil];
	NSMutableDictionary *urls = [NSMutableDictionary dictionaryWithCapacity:[files count]];
	BOOL createdAll = YES;
	for (NSString *name in files) {
		NSURL *url = [sessionURL URLByAppendingPathComponent:name];
		[urls setObject:url forKey:name];
		if (!CoordinatedWrite(url, [files objectForKey:name], &error)) {
			createdAll = NO;
			ReportError(@"FAIL", @"SETUP", error);
			break;
		}
	}

	BOOL uploadedAll = createdAll;
	if (ubiquitousByManager) {
		for (NSURL *url in [urls allValues]) {
			if (!WaitUntilUploaded(url, timeout)) {
				uploadedAll = NO;
				break;
			}
		}
		Report(uploadedAll ? @"PASS" : @"FAIL", @"AV-01-upload", uploadedAll ? @"test items reached uploaded state" : @"upload did not settle");
	}

	NSDictionary *catalog = CoordinatedCatalog(sessionURL, &error);
	NSSet *catalogNames = [NSSet setWithArray:[catalog allKeys]];
	NSSet *expectedNames = [NSSet setWithArray:[files allKeys]];
	if (catalog && [catalogNames isEqualToSet:expectedNames])
		Report(@"PASS", @"AV-03", @"coordinated shallow catalog was complete");
	else
		ReportError(@"FAIL", @"AV-03", error);
	TestCatalogFenceContracts(sessionURL);

	NSURL *downloadURL = [urls objectForKey:@"download.bin"];
	NSURL *batchURL = [urls objectForKey:@"batch-selected.bin"];
	NSURL *siblingURL = [urls objectForKey:@"batch-sibling.bin"];
	if (ubiquitousByManager && uploadedAll) {
		BOOL evictedDownload = [manager evictUbiquitousItemAtURL:downloadURL error:&error] && WaitUntilNotDownloaded(downloadURL, timeout);
		BOOL evictedBatch = [manager evictUbiquitousItemAtURL:batchURL error:&error] && WaitUntilNotDownloaded(batchURL, timeout);
		BOOL evictedSibling = [manager evictUbiquitousItemAtURL:siblingURL error:&error] && WaitUntilNotDownloaded(siblingURL, timeout);
		if (evictedDownload && evictedBatch && evictedSibling) {
			NSArray *metadataKeys = [NSArray arrayWithObjects:NSURLIsUbiquitousItemKey,
				NSURLUbiquitousItemDownloadingStatusKey, NSURLUbiquitousItemDownloadingErrorKey, nil];
			NSDictionary *metadata = CoordinatedPromisedMetadata(downloadURL, metadataKeys, &error);
			BOOL metadataStayedEvicted = metadata &&
				[[metadata objectForKey:NSURLIsUbiquitousItemKey] boolValue] &&
				IsDownloadStatus(downloadURL, NSURLUbiquitousItemDownloadingStatusNotDownloaded);
			Report(metadataStayedEvicted ? @"PASS" : @"FAIL", @"AV-01-metadata",
				metadataStayedEvicted ? @"promised metadata accessor did not materialize content" : @"promised metadata was incomplete or materialized content");

			catalog = CoordinatedCatalog(sessionURL, &error);
			BOOL siblingStillEvicted = IsDownloadStatus(siblingURL, NSURLUbiquitousItemDownloadingStatusNotDownloaded);
			Report(catalog && siblingStillEvicted ? @"PASS" : @"FAIL", @"AV-03-materialization",
				catalog && siblingStillEvicted ? @"catalog left child content evicted" : @"catalog materialized child content or failed");

			BOOL requested = [manager startDownloadingUbiquitousItemAtURL:downloadURL error:&error];
			BOOL current = requested && WaitUntilCurrent(downloadURL, timeout);
			NSData *downloaded = current ? CoordinatedRead(downloadURL, &error) : nil;
			Report(current && [downloaded isEqual:downloadData] ? @"PASS" : @"FAIL", @"AV-02",
				current && [downloaded isEqual:downloadData] ? @"exact item materialized and read completely" : @"exact item failed materialization/read");

			BOOL batchOK = TestBatchRead(batchURL, batchData, siblingURL, timeout);
			Report(batchOK ? @"PASS" : @"FAIL", @"AV-04",
				batchOK ? @"batch read materialized only selected content" : @"batch accessor contract differed");
		} else
			ReportError(@"FAIL", @"AV-02/03/04", error);
	} else {
		Report(@"SKIP", @"AV-02/03/04", @"requires an uploaded ubiquitous item");
	}

	NSURL *versionedURL = [urls objectForKey:@"versioned.txt"];
	error = nil;
	NSFileVersion *currentVersion = CoordinatedCurrentVersion(versionedURL, &error);
	id persistentID = [currentVersion persistentIdentifier];
	NSFileVersion *repeatedVersion = CoordinatedCurrentVersion(versionedURL, &error);
	BOOL identityStable = currentVersion && persistentID &&
		[(NSObject *)[repeatedVersion persistentIdentifier] isEqual:persistentID];
	NSString *versionFailureKind = required ? @"FAIL" : @"OBSERVE";
	Report(identityStable ? @"PASS" : versionFailureKind, @"AV-05-current-observation", identityStable ?
		@"current version identity was repeat-stable within one coordinated attempt" :
		[NSString stringWithFormat:@"current observation was incomplete error=%@", ErrorCode(error)]);

	NSURL *versionSourceURL = [sessionURL URLByAppendingPathComponent:@"version-source.tmp"];
	BOOL addedSyntheticVersion = CoordinatedWrite(versionSourceURL, [@"historical" dataUsingEncoding:NSUTF8StringEncoding], &error);
	NSFileVersion *syntheticVersion = addedSyntheticVersion ? CoordinatedAddVersion(versionedURL, versionSourceURL, &error) : nil;
	if (syntheticVersion) {
		id syntheticID = [(NSObject *)[syntheticVersion persistentIdentifier] retain];
		CoordinatedDelete(versionedURL, NULL);
		NSArray *afterDelete = [NSFileVersion otherVersionsOfItemAtURL:versionedURL];
		BOOL found = NO;
		for (NSFileVersion *version in afterDelete)
			found |= [(NSObject *)[version persistentIdentifier] isEqual:syntheticID];
		Report(found ? @"PASS" : @"OBSERVE", @"AV-06", found ? @"retained URL disclosed history after current deletion" : @"history was not disclosed after current deletion");
		[syntheticID release];
	} else
		ReportError(@"SKIP", @"AV-06", error);
	CoordinatedDelete(versionSourceURL, NULL);

	if (@available(macOS 26.0, *)) {
		TestMacOS26SyncControls([urls objectForKey:@"sync-control.bin"], timeout);
		TestMacOS26AtomicReplacement([urls objectForKey:@"sync-control.bin"], timeout);
	} else
		Report(@"SKIP", @"AV-10", @"requires macOS 26 or later");
	Report(@"OBSERVE", @"AV-11", @"run the dedicated legacy-upload mode on each required pre-macOS-26 target");

	TestProviderIdentity(rootURL, [urls objectForKey:@"sync-control.bin"], timeout);

	NSUInteger eventsBefore = [presenter eventCount];
	int childStatus = RunChild([NSArray arrayWithObjects:@"child-mutate", [sessionURL path], nil]);
	BOOL gotEvents = WaitFor(10.0, ^BOOL{ return [presenter eventCount] > eventsBefore; });
	Report(childStatus == 0 && gotEvents ? @"PASS" : @"FAIL", @"AV-07",
		childStatus == 0 && gotEvents ? @"cross-process coordinated mutation reached presenter" : @"presenter missed cross-process mutation");

	eventsBefore = [presenter eventCount];
	int rawStatus = RunChild([NSArray arrayWithObjects:@"child-raw-mutate", [sessionURL path], nil]);
	NSURL *rawURL = [sessionURL URLByAppendingPathComponent:@"raw-b.txt"];
	BOOL rawVisible = rawStatus == 0 &&
		[CoordinatedRead(rawURL, &error) isEqual:[@"two" dataUsingEncoding:NSUTF8StringEncoding]];
	BOOL rawCallback = WaitFor(5.0, ^BOOL{ return [presenter eventCount] > eventsBefore; });
	Report(rawVisible ? @"PASS" : @"FAIL", @"AV-07-raw-observation",
		rawVisible ? @"later coordinated observation saw the exact uncoordinated mutation" :
		[NSString stringWithFormat:@"child=%d error=%@", rawStatus, ErrorCode(error)]);
	Report(rawCallback ? @"PASS" : @"OBSERVE", @"AV-07-raw-presenter",
		rawCallback ? @"presenter also reported activity for the uncoordinated mutation" :
		@"no presenter callback arrived; observation cannot rely on NSFilePresenter alone");

	[NSFileCoordinator removeFilePresenter:presenter];

	if (!CoordinatedDelete(sessionURL, &error))
		ReportError(@"FAIL", @"CLEANUP", error);
	else
		Report(@"PASS", @"CLEANUP", @"test-owned subtree removed");

	TestPathIndependentProviderOperations(rootURL, required, timeout);

	Report(@"PASS", @"AV-12", @"suite completed without metadata-query dependency");
	return failures == 0 ? 0 : 1;
}

#include "ICloudRootLockProbe.h"
#include "ICloudMetadataProbe.h"

static void PrintUsage(void) {
	fprintf(stderr, "usage: ICloudAPIContractTest local ROOT [required|observe]\n"
		"       ICloudAPIContractTest foundation ROOT [required|observe]\n"
		"       ICloudAPIContractTest metadata-probe ROOT\n"
		"       ICloudAPIContractTest metadata-inspect SESSION\n"
		"       ICloudAPIContractTest binding ROOT prepare | binding SESSION ACTION [LEAF]\n"
		"       ICloudAPIContractTest root-lock-control LOCAL_TEST_ROOT\n"
		"       ICloudAPIContractTest root-lock-directory TEST_ROOT\n"
		"       ICloudAPIContractTest root-lock-prepare ROOT UPPERCASE_RUN_UUID\n"
		"       ICloudAPIContractTest root-lock-watch ROOT RUN_UUID cold|held|race [START_EPOCH]\n"
		"       ICloudAPIContractTest root-lock-evict|root-lock-download|root-lock-replace|root-lock-inspect ROOT RUN_UUID cold|held|race\n"
		"       ICloudAPIContractTest wal-reboot-prepare TEST_DIRECTORY\n"
		"       ICloudAPIContractTest wal-reboot-verify TEST_DIRECTORY\n"
		"       ICloudAPIContractTest identity-restart SESSION_ROOT\n"
		"       ICloudAPIContractTest child-move-root-marked SOURCE DESTINATION MARKER\n"
		"       ICloudAPIContractTest legacy-upload ROOT\n"
		"       ICloudAPIContractTest history-restart SESSION_ROOT\n"
		"       ICloudAPIContractTest conflict-prepare ROOT\n"
		"       ICloudAPIContractTest conflict-materialize ROOT\n"
		"       ICloudAPIContractTest conflict-write ROOT host|peer START_EPOCH [SOURCE_ID_PLIST]\n"
		"       ICloudAPIContractTest conflict-inspect ROOT [required]\n"
		"       ICloudAPIContractTest conflict-edit-delete-write ROOT edit|delete START_EPOCH\n"
		"       ICloudAPIContractTest conflict-edit-delete-inspect ROOT\n"
		"       ICloudAPIContractTest conflict-export-identifiers ROOT OUTPUT_PLIST\n"
		"       ICloudAPIContractTest conflict-compare-identifiers ROOT INPUT_PLIST\n"
		"       ICloudAPIContractTest conflict-disposition ROOT [required]\n"
		"       ICloudAPIContractTest cleanup-conflict ROOT\n"
		"       ICloudAPIContractTest manifest-host ROOT\n"
		"       ICloudAPIContractTest manifest-peer ROOT\n"
		"       ICloudAPIContractTest cleanup-manifest ROOT\n"
		"       ICloudAPIContractTest sync-conflict-host ROOT\n"
		"       ICloudAPIContractTest sync-conflict-peer ROOT\n"
		"       ICloudAPIContractTest sync-control-probe ROOT\n"
		"       ICloudAPIContractTest pause-lifecycle-prepare ROOT\n"
		"       ICloudAPIContractTest pause-lifecycle-repair ROOT\n"
		"       ICloudAPIContractTest cleanup-sync-conflict ROOT\n"
		"       ICloudAPIContractTest remote-host ROOT\n"
		"       ICloudAPIContractTest remote-peer ROOT\n"
		"       ICloudAPIContractTest xattr-host ROOT\n"
		"       ICloudAPIContractTest xattr-peer ROOT\n"
		"       ICloudAPIContractTest cleanup-xattr ROOT\n"
		"       ICloudAPIContractTest cleanup-local ROOT\n"
		"       ICloudAPIContractTest cleanup-remote ROOT\n");
}

int main(int argc, const char *argv[]) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	int status = 2;
	if (argc >= 3) {
		NSString *mode = [NSString stringWithUTF8String:argv[1]];
		NSURL *firstURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
		NSTimeInterval timeout = [[[NSProcessInfo processInfo] environment][@"NV_ICLOUD_API_TEST_TIMEOUT"] doubleValue];
		if (timeout <= 0.0)
			timeout = 180.0;
		if ([mode isEqualToString:@"binding"] && argc >= 4)
			status = RunBindingProbe(firstURL, [NSString stringWithUTF8String:argv[3]],
				argc >= 5 ? [NSString stringWithUTF8String:argv[4]] : @"note.bin", timeout);
		else if ([mode isEqualToString:@"metadata-probe"])
			status = RunMetadataProbe(firstURL, timeout);
		else if ([mode isEqualToString:@"metadata-inspect"])
			status = RunMetadataInspect(firstURL, timeout);
		else if ([mode hasPrefix:@"root-lock-"])
			status = RunRootLockProbe(mode, firstURL, argc, argv, timeout);
		else if ([mode isEqualToString:@"child-mutate"])
			status = ChildMutate(firstURL);
		else if ([mode isEqualToString:@"child-raw-mutate"])
			status = ChildRawMutate(firstURL);
		else if ([mode isEqualToString:@"child-wal-write"])
			status = ChildWALWrite(firstURL);
		else if ([mode isEqualToString:@"provider-reverse-child"])
			status = RunProviderReverseChild(firstURL, timeout);
		else if ([mode isEqualToString:@"wal-reboot-prepare"])
			status = RunWALRebootPrepare(firstURL);
		else if ([mode isEqualToString:@"wal-reboot-verify"])
			status = RunWALRebootVerify(firstURL);
		else if ([mode isEqualToString:@"identity-restart"])
			status = RunIdentityRestartObservation(firstURL);
		else if ([mode isEqualToString:@"child-move-root"] && argc >= 4)
			status = ChildMoveRoot(firstURL, [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]] isDirectory:YES]);
		else if ([mode isEqualToString:@"child-move-root-marked"] && argc >= 5)
			status = ChildMoveRootMarked(firstURL,
				[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]] isDirectory:YES],
				[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[4]] isDirectory:NO]);
		else if ([mode isEqualToString:@"legacy-upload"])
			status = RunLegacyUploadTransition(firstURL, timeout);
		else if ([mode isEqualToString:@"history-restart"])
			status = RunHistoryRestartInspect(firstURL, timeout);
		else if ([mode isEqualToString:@"conflict-prepare"])
			status = RunConflictPrepare(firstURL, timeout);
		else if ([mode isEqualToString:@"conflict-materialize"])
			status = RunConflictMaterialize(firstURL, timeout);
		else if ([mode isEqualToString:@"conflict-write"] && argc >= 5)
			status = RunConflictWrite(firstURL, [NSString stringWithUTF8String:argv[3]],
				[[NSString stringWithUTF8String:argv[4]] doubleValue], timeout,
				argc >= 6 ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[5]]] : nil);
		else if ([mode isEqualToString:@"conflict-inspect"])
			status = RunConflictInspect(firstURL, timeout,
				argc >= 4 && !strcmp(argv[3], "required"));
		else if ([mode isEqualToString:@"conflict-edit-delete-write"] && argc >= 5)
			status = RunConflictEditDeleteWrite(firstURL,
				[NSString stringWithUTF8String:argv[3]],
				[[NSString stringWithUTF8String:argv[4]] doubleValue]);
		else if ([mode isEqualToString:@"conflict-edit-delete-inspect"])
			status = RunConflictEditDeleteInspect(firstURL, timeout);
		else if ([mode isEqualToString:@"conflict-export-identifiers"] && argc >= 4)
			status = RunConflictExportIdentifiers(firstURL,
				[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]], timeout);
		else if ([mode isEqualToString:@"conflict-compare-identifiers"] && argc >= 4)
			status = RunConflictCompareIdentifiers(firstURL,
				[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]], timeout);
		else if ([mode isEqualToString:@"conflict-disposition"])
			status = RunConflictDisposition(firstURL, timeout,
				argc >= 4 && !strcmp(argv[3], "required"));
		else if ([mode isEqualToString:@"cleanup-conflict"])
			status = CleanupConflictSession(firstURL);
		else if ([mode isEqualToString:@"manifest-host"])
			status = RunManifestHost(firstURL, timeout);
		else if ([mode isEqualToString:@"manifest-peer"])
			status = RunManifestPeer(firstURL, timeout);
		else if ([mode isEqualToString:@"cleanup-manifest"])
			status = CleanupManifestSession(firstURL);
		else if ([mode isEqualToString:@"sync-conflict-host"]) {
			if (@available(macOS 26.0, *))
				status = RunSyncConflictHost(firstURL, timeout);
			else
				status = 3;
		}
		else if ([mode isEqualToString:@"sync-conflict-peer"])
			status = RunSyncConflictPeer(firstURL, timeout);
		else if ([mode isEqualToString:@"sync-control-probe"]) {
			if (@available(macOS 26.0, *))
				status = RunSyncControlProbe(firstURL, timeout);
			else
				status = 3;
		}
		else if ([mode isEqualToString:@"pause-lifecycle-prepare"]) {
			if (@available(macOS 26.0, *))
				status = RunPauseLifecyclePrepare(firstURL, timeout);
			else
				status = 3;
		}
		else if ([mode isEqualToString:@"pause-lifecycle-repair"]) {
			if (@available(macOS 26.0, *))
				status = RunPauseLifecycleRepair(firstURL, timeout);
			else
				status = 3;
		}
		else if ([mode isEqualToString:@"cleanup-sync-conflict"])
			status = CleanupSyncConflictSession(firstURL);
		else if ([mode isEqualToString:@"remote-host"])
			status = RunRemoteHost(firstURL, timeout);
		else if ([mode isEqualToString:@"remote-peer"])
			status = RunRemotePeer(firstURL, timeout);
		else if ([mode isEqualToString:@"xattr-host"])
			status = RunXAttrHost(firstURL, timeout);
		else if ([mode isEqualToString:@"xattr-peer"])
			status = RunXAttrPeer(firstURL, timeout);
		else if ([mode isEqualToString:@"cleanup-xattr"])
			status = CleanupXAttrSession(firstURL);
		else if ([mode isEqualToString:@"cleanup-local"])
			status = CleanupLocalSession(firstURL);
		else if ([mode isEqualToString:@"cleanup-remote"])
			status = CleanupRemoteSession(firstURL);
		else if ([mode isEqualToString:@"local"]) {
			NSString *testPolicy = argc >= 4 ? [NSString stringWithUTF8String:argv[3]] : @"observe";
			status = RunLocal(firstURL, testPolicy, timeout);
		} else if ([mode isEqualToString:@"foundation"]) {
			NSString *testPolicy = argc >= 4 ? [NSString stringWithUTF8String:argv[3]] : @"observe";
			BOOL required = [testPolicy isEqualToString:@"required"] ||
				[testPolicy isEqualToString:@"icloud"];
			RunFoundationReplacementContracts(firstURL, required, timeout);
			RunLocalWALContracts();
			status = failures == 0 ? 0 : 1;
		} else
			PrintUsage();
	} else
		PrintUsage();
	[pool drain];
	return status;
}
