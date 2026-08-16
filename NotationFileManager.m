//
//  NotationFileManager.m
//  Notation
//
//  Created by Zachary Schneirov on 4/9/06.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#import "NotationFileManager.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NSData_transformations.h"
#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <sys/xattr.h>
#include <unistd.h>

NSString *NotesDatabaseFileName = @"Notes & Settings";

typedef BOOL (^NVFilePreparationBlock)(int fileDescriptor, NSError **error);

@interface NotationController (NVFileManagerTestSeams)
- (BOOL)_setCocoaTags:(NSArray*)tags atURL:(NSURL*)URL error:(NSError**)error;
- (void)_didSynchronizeTagsForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor;
- (void)_didSetTextEncodingForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor;
- (void)_didPrepareNoteFileNamed:(NSString*)filename;
- (void)_didRejectAtomicSwapForNoteNamed:(NSString*)filename;
- (void)_didExchangeNoteFileNamed:(NSString*)filename;
- (int)_metadataFinalizationErrorAfterExchangingNoteNamed:(NSString*)filename;
- (void)_didObserveRenameCollisionFromName:(NSString*)oldName toName:(NSString*)newName;
- (BOOL)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename
	preparationBlock:(NVFilePreparationBlock)preparationBlock
	verificationBlock:(NVFileVerificationBlock)verificationBlock error:(NSError**)error;
@end

@implementation NotationController (NotationFileManager)

static NSError *NVErrorFromErrno(int errorNumber, NSString *operation, NSString *filename) {
	NSString *description = filename ?
		[NSString stringWithFormat:@"%@ '%@': %s", operation, filename, strerror(errorNumber)] :
		[NSString stringWithFormat:@"%@: %s", operation, strerror(errorNumber)];
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errorNumber
		userInfo:[NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey]];
}

static BOOL NVFileSystemName(NSString *filename, char **name, NSError **error) {
	if (![filename length] || [filename isEqualToString:@"."] || [filename isEqualToString:@".."] ||
		[filename rangeOfString:@"/"].location != NSNotFound) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Invalid filename", filename);
		return NO;
	}
	NSUInteger size = [filename maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
	char *buffer = malloc(size);
	if (!buffer) {
		if (error) *error = NVErrorFromErrno(ENOMEM, @"Represent filename", filename);
		return NO;
	}
	if (![filename getFileSystemRepresentation:buffer maxLength:size] || strchr(buffer, '/')) {
		free(buffer);
		if (error) *error = NVErrorFromErrno(ENAMETOOLONG, @"Represent filename", filename);
		return NO;
	}
	*name = buffer;
	return YES;
}

/* case-sensitive filesystems have no case-folding exclusive create;
 * this descriptor-relative scan enforces the app's policy absent a concurrent
 * external creator. Add a native case-folding namespace primitive if one appears. */
static BOOL NVCaseInsensitiveNameExists(int directoryFileDescriptor,
	NSString *filename, NSString *ignoredName) {
	int scanFD = openat(directoryFileDescriptor, ".",
		O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	DIR *directory = scanFD >= 0 ? fdopendir(scanFD) : NULL;
	if (!directory) {
		if (scanFD >= 0) close(scanFD);
		return NO;
	}
	BOOL exists = NO;
	struct dirent *entry;
	while ((entry = readdir(directory))) {
		NSString *name = [[NSFileManager defaultManager]
			stringWithFileSystemRepresentation:entry->d_name length:entry->d_namlen];
		if (![name isEqualToString:ignoredName] &&
			[name caseInsensitiveCompare:filename] == NSOrderedSame) {
			exists = YES;
			break;
		}
	}
	closedir(directory);
	return exists;
}

static int NVExchangeDataAtDirectoryFileDescriptor(int directoryFileDescriptor,
	const char *firstName, const char *secondName) {
	char directoryPath[PATH_MAX];
	if (fcntl(directoryFileDescriptor, F_GETPATH, directoryPath) < 0) return -1;
	size_t directoryLength = strlen(directoryPath);
	size_t firstLength = strlen(firstName), secondLength = strlen(secondName);
	if (directoryLength + 1 + MAX(firstLength, secondLength) + 1 > PATH_MAX) {
		errno = ENAMETOOLONG;
		return -1;
	}
	char firstPath[PATH_MAX], secondPath[PATH_MAX];
	memcpy(firstPath, directoryPath, directoryLength);
	firstPath[directoryLength] = '/';
	memcpy(firstPath + directoryLength + 1, firstName, firstLength + 1);
	memcpy(secondPath, directoryPath, directoryLength);
	secondPath[directoryLength] = '/';
	memcpy(secondPath + directoryLength + 1, secondName, secondLength + 1);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	int result = exchangedata(firstPath, secondPath, FSOPT_NOFOLLOW_ANY | FSOPT_UNIQUE);
#pragma clang diagnostic pop
	return result;
}

static NSData *NVReadDataFromFileDescriptor(int fileDescriptor, NSError **error) {
	struct stat info;
	if (fstat(fileDescriptor, &info) < 0) {
		if (error) *error = NVErrorFromErrno(errno, @"Inspect file", nil);
		return nil;
	}
	if (!S_ISREG(info.st_mode) || info.st_size < 0 || (uint64_t)info.st_size > NSUIntegerMax) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Read non-regular file", nil);
		return nil;
	}
	NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
	uint8_t *bytes = [data mutableBytes];
	size_t remaining = (size_t)info.st_size;
	off_t offset = 0;
	while (remaining) {
		ssize_t amount = pread(fileDescriptor, bytes + offset, remaining, offset);
		if (amount < 0 && errno == EINTR) continue;
		if (amount <= 0) {
			if (error) *error = NVErrorFromErrno(amount < 0 ? errno : EIO, @"Read file", nil);
			return nil;
		}
		offset += amount;
		remaining -= (size_t)amount;
	}
	return data;
}

static BOOL NVURLReferencesFileDescriptor(NSURL *URL, int fileDescriptor) {
	NSURL *descriptorURL = [NSURL fileURLWithPath:
		[NSString stringWithFormat:@"/dev/fd/%d", fileDescriptor]];
	return NVURLsReferToSameItem(URL, descriptorURL);
}

typedef struct __attribute__((packed, aligned(4))) {
	uint32_t length;
	attribute_set_t returned;
	fsobj_type_t objectType;
	struct timespec creationTime;
	struct timespec modificationTime;
	struct timespec changeTime;
	uint32_t generationCount;
	uint32_t documentID;
	uint64_t fileID;
	off_t logicalSize;
} NVFileAttributes;

_Static_assert(offsetof(NVFileAttributes, returned) == 4, "returned attribute offset");
_Static_assert(offsetof(NVFileAttributes, objectType) == 24, "object type attribute offset");
_Static_assert(offsetof(NVFileAttributes, creationTime) == 28, "creation time attribute offset");
_Static_assert(offsetof(NVFileAttributes, generationCount) == 76, "generation count attribute offset");
_Static_assert(offsetof(NVFileAttributes, fileID) == 84, "file ID attribute offset");
_Static_assert(offsetof(NVFileAttributes, logicalSize) == 92, "logical size attribute offset");

static struct attrlist NVFileInfoAttributeRequest(void) {
	struct attrlist requested;
	bzero(&requested, sizeof(requested));
	requested.bitmapcount = ATTR_BIT_MAP_COUNT;
	requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME |
		ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_GEN_COUNT |
		ATTR_CMN_DOCUMENT_ID | ATTR_CMN_FILEID;
	requested.fileattr = ATTR_FILE_DATALENGTH;
	return requested;
}

static BOOL NVStoreFileInfoFromAttributes(NVFileAttributes *attributes, int result,
	int statusError, NVFileInfo *info, NSError **error) {
	const attrgroup_t mandatoryCommon = ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME |
		ATTR_CMN_CHGTIME | ATTR_CMN_FILEID;
	if (result < 0 || attributes->length < sizeof(*attributes) || attributes->objectType != VREG ||
		(attributes->returned.commonattr & mandatoryCommon) != mandatoryCommon ||
		!(attributes->returned.fileattr & ATTR_FILE_DATALENGTH)) {
		if (error) *error = NVErrorFromErrno(result < 0 ? statusError : EINVAL, @"Inspect file", nil);
		return NO;
	}
	memcpy(&info->creationTime, &attributes->creationTime, sizeof(info->creationTime));
	memcpy(&info->modificationTime, &attributes->modificationTime, sizeof(info->modificationTime));
	memcpy(&info->attributeModificationTime, &attributes->changeTime, sizeof(info->attributeModificationTime));
	memcpy(&info->logicalSize, &attributes->logicalSize, sizeof(info->logicalSize));
	memcpy(&info->fileID, &attributes->fileID, sizeof(info->fileID));
	info->documentID = (attributes->returned.commonattr & ATTR_CMN_DOCUMENT_ID) ?
		attributes->documentID : 0;
	info->generationCount = (attributes->returned.commonattr & ATTR_CMN_GEN_COUNT) ?
		attributes->generationCount : 0;
	return YES;
}

static BOOL NVGetFileInfoFromDescriptor(int fileDescriptor, NVFileInfo *info, NSError **error) {
	struct attrlist requested = NVFileInfoAttributeRequest();
	NVFileAttributes attributes = { 0 };
	int result = fgetattrlist(fileDescriptor, &requested, &attributes, sizeof(attributes),
		FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS);
	return NVStoreFileInfoFromAttributes(&attributes, result, errno, info, error);
}

static BOOL NVGetFileInfoAtDirectoryFileDescriptor(int directoryFileDescriptor,
	const char *name, NVFileInfo *info, NSError **error) {
	struct attrlist requested = NVFileInfoAttributeRequest();
	NVFileAttributes attributes = { 0 };
	int result = getattrlistat(directoryFileDescriptor, name, &requested, &attributes,
		sizeof(attributes), FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS);
	return NVStoreFileInfoFromAttributes(&attributes, result, errno, info, error);
}

static NSData *NVExtendedAttributeData(int fileDescriptor, const char *name,
	BOOL *present, NSError **error) {
	if (present) *present = NO;
	ssize_t length = fgetxattr(fileDescriptor, name, NULL, 0, 0, 0);
	if (length < 0) {
		if (errno == ENOATTR) return nil;
		if (error) *error = NVErrorFromErrno(errno, @"Read extended attribute", nil);
		return nil;
	}
	NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
	ssize_t actualLength = fgetxattr(fileDescriptor, name, [data mutableBytes], [data length], 0, 0);
	if (actualLength < 0) {
		int xattrError = errno;
		if (error) *error = NVErrorFromErrno(xattrError == ERANGE || xattrError == ENOATTR ? EAGAIN : xattrError,
			@"Read extended attribute", nil);
		return nil;
	}
	[data setLength:(NSUInteger)actualLength];
	if (present) *present = YES;
	return data;
}

static BOOL NVParseTextEncoding(NSData *data, NSStringEncoding *encoding, NSError **error) {
	NSString *value = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	NSArray *parts = [value componentsSeparatedByString:@";"];
	CFStringEncoding cfEncoding = kCFStringEncodingInvalidId;
	if ([parts count] > 1) {
		NSScanner *scanner = [NSScanner scannerWithString:[parts objectAtIndex:1]];
		long long numericEncoding = 0;
		if ([scanner scanLongLong:&numericEncoding] && [scanner isAtEnd] &&
			numericEncoding >= 0 && numericEncoding <= UINT32_MAX)
			cfEncoding = (CFStringEncoding)numericEncoding;
	} else if ([parts count] == 1) {
		cfEncoding = CFStringConvertIANACharSetNameToEncoding((CFStringRef)[parts objectAtIndex:0]);
	}
	if (!value || cfEncoding == kCFStringEncodingInvalidId || !CFStringIsEncodingAvailable(cfEncoding)) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Parse text encoding attribute", nil);
		return NO;
	}
	if (encoding) *encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding);
	return YES;
}

static NSArray *NVParseTags(NSData *data, NSError **error) {
	id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
		format:NULL error:error];
	if (![value isKindOfClass:[NSArray class]]) {
		if (error && !*error) *error = NVErrorFromErrno(EINVAL, @"Parse tags attribute", nil);
		return nil;
	}
	for (id tag in value) {
		if (![tag isKindOfClass:[NSString class]]) {
			if (error) *error = NVErrorFromErrno(EINVAL, @"Parse tags attribute", nil);
			return nil;
		}
	}
	return value;
}

static BOOL NVTimespecEqual(struct timespec one, struct timespec two) {
	return one.tv_sec == two.tv_sec && one.tv_nsec == two.tv_nsec;
}

static BOOL NVFileRevisionEqual(const NVFileInfo *one, const NVFileInfo *two) {
	return one->fileID == two->fileID && one->logicalSize == two->logicalSize &&
		NVTimespecEqual(one->modificationTime, two->modificationTime) &&
		NVTimespecEqual(one->attributeModificationTime, two->attributeModificationTime) &&
		(!one->generationCount || !two->generationCount ||
			one->generationCount == two->generationCount);
}

static BOOL NVDescriptorContainsStableData(int fileDescriptor, NSData *expectedData,
	const NVFileInfo *before, NVFileInfo *after, NSError **error) {
	/* Call only after our own xattr writes: those writes legitimately change ctime
	 * and generation, while this second bracket can reject any later mutation. */
	NSData *observedData = expectedData ? NVReadDataFromFileDescriptor(fileDescriptor, error) : nil;
	if (expectedData && !observedData) return NO;
	if (!NVGetFileInfoFromDescriptor(fileDescriptor, after, error)) return NO;
	return NVFileRevisionEqual(before, after) &&
		(!expectedData || [observedData isEqualToData:expectedData]);
}

NSArray *NVSemanticTagNames(NSArray *tags) {
	if (![tags isKindOfClass:[NSArray class]]) return nil;
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:[tags count]];
	for (id tag in tags) {
		if (![tag isKindOfClass:[NSString class]]) return nil;
		NSString *name = tag;
		NSUInteger length = [name length];
		if (length >= 2 && [name characterAtIndex:length - 2] == '\n' &&
			[name characterAtIndex:length - 1] >= '0' && [name characterAtIndex:length - 1] <= '7')
			[names addObject:[name substringToIndex:length - 2]];
		else [names addObject:tag];
	}
	return names;
}

static BOOL NVSynchronizeOpenMetaAndCocoaTagsInternal(int directoryFileDescriptor,
	int fileDescriptor, NSURL *directoryReferenceURL, NSString *filename, NSArray *tags,
	const NVFileInfo *expectedFileInfo, NVFileInfo *resultingFileInfo,
	NSData *expectedData, BOOL hideExtension, NotationController *testObserver,
	NSError **error) {
	/* Finder tags and OpenMeta tags are separate interfaces on current macOS.
	 * Write Finder's URL value first, then restore the exact OpenMeta plist on the
	 * descriptor; this preserves OpenMeta color suffixes and present-empty state.
	 * The URL side is best-effort because providers may not implement it, while
	 * the descriptor xattr and final root-relative identity check are authoritative. */
	if (tags && ![tags isKindOfClass:[NSArray class]]) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Encode file tags", filename);
		return NO;
	}
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return NO;
	NSData *data = tags ? [NSPropertyListSerialization dataWithPropertyList:tags
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:error] : nil;
	NSArray *cocoaTags = tags ? NVSemanticTagNames(tags) : @[];
	if ((tags && !data) || !cocoaTags) {
		free(name);
		if (error && !*error) *error = NVErrorFromErrno(EINVAL, @"Encode file tags", filename);
		return NO;
	}
	int fd = fileDescriptor;
	NVFileInfo before = { 0 }, afterTags = { 0 }, after = { 0 };
	BOOL expectedMatches = NVGetFileInfoFromDescriptor(fd, &before, error) &&
		(!expectedFileInfo || (before.fileID == expectedFileInfo->fileID &&
		before.logicalSize == expectedFileInfo->logicalSize &&
		NVTimespecEqual(before.modificationTime, expectedFileInfo->modificationTime) &&
		NVTimespecEqual(before.attributeModificationTime,
			expectedFileInfo->attributeModificationTime) &&
		(!before.generationCount || !expectedFileInfo->generationCount ||
			before.generationCount == expectedFileInfo->generationCount)));
	if (!expectedMatches) {
		free(name);
		if (error && !*error) *error = NVErrorFromErrno(EAGAIN, @"Tag changing file", filename);
		return NO;
	}
	NSURL *URL = [[NSFileManager defaultManager] fileReferenceURLForFilename:filename
		inDirectoryURL:directoryReferenceURL error:NULL];
	NSError *cocoaError = nil;
	struct stat descriptorStatus = { 0 };
	BOOL URLMatches = URL && NVURLReferencesFileDescriptor(URL, fd);
	if (!URLMatches)
		NSLog(@"Could not mirror OpenMeta tags to Finder tags for '%@': URL identity unavailable", filename);
	else if (!(testObserver ? [testObserver _setCocoaTags:cocoaTags atURL:URL error:&cocoaError] :
		[URL setResourceValue:cocoaTags forKey:NSURLTagNamesKey error:&cocoaError]))
		NSLog(@"Could not mirror OpenMeta tags to Finder tags for '%@': %@", filename, cocoaError);
	if (URLMatches && hideExtension &&
		![URL setResourceValue:@YES forKey:NSURLHasHiddenExtensionKey error:&cocoaError])
		NSLog(@"Could not hide extension for '%@': %@", filename, cocoaError);
	int result = data ? fsetxattr(fd, "com.apple.metadata:kMDItemOMUserTags",
		[data bytes], [data length], 0, 0) : fremovexattr(fd,
		"com.apple.metadata:kMDItemOMUserTags", 0);
	int xattrError = errno;
	if (result == 0 && fsync(fd) < 0) { result = -1; xattrError = errno; }
	BOOL xattrSucceeded = result == 0 || (data == nil && xattrError == ENOATTR);
	BOOL stable = xattrSucceeded && NVGetFileInfoFromDescriptor(fd, &afterTags, error);
	if (stable && testObserver)
		[testObserver _didSynchronizeTagsForNoteNamed:filename fileDescriptor:fd];
	if (stable)
		stable = NVDescriptorContainsStableData(fd, expectedData, &afterTags, &after, error);
	struct stat namedStatus = { 0 };
	BOOL sameFile = stable &&
		fstat(fd, &descriptorStatus) == 0 &&
		fstatat(directoryFileDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
		descriptorStatus.st_dev == namedStatus.st_dev && descriptorStatus.st_ino == namedStatus.st_ino;
	free(name);
	if (result < 0 && !(data == nil && xattrError == ENOATTR)) {
		if (error && !*error) *error = NVErrorFromErrno(xattrError, @"Set file tags", filename);
		return NO;
	}
	if (!sameFile) {
		if (error && !*error) *error = NVErrorFromErrno(EAGAIN, @"Tag changing file", filename);
		return NO;
	}
	if (resultingFileInfo) *resultingFileInfo = after;
	return YES;
}
static BOOL NVWriteDataToFileDescriptor(NSData *data, int fileDescriptor, NSError **error) {
	const uint8_t *bytes = [data bytes];
	size_t remaining = [data length];
	while (remaining) {
		ssize_t amount = write(fileDescriptor, bytes, remaining);
		if (amount < 0 && errno == EINTR) continue;
		if (amount <= 0) {
			if (error) *error = NVErrorFromErrno(amount < 0 ? errno : EIO, @"Write file", nil);
			return NO;
		}
		bytes += amount;
		remaining -= (size_t)amount;
	}
	return YES;
}

- (NSURL*)fileReferenceURLForNoteNamed:(NSString*)filename error:(NSError**)error {
	return [[NSFileManager defaultManager] fileReferenceURLForFilename:filename
		inDirectoryURL:noteDirectoryURL error:error];
}

- (BOOL)noteExistsWithName:(NSString*)filename {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, NULL)) return NO;
	struct stat info;
	BOOL exists = fstatat(noteDirectoryFileDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(info.st_mode);
	free(name);
	return exists;
}

- (NSData*)dataFromNoteNamed:(NSString*)filename error:(NSError**)error {
	return [self dataFromNoteNamed:filename creatingIfMissing:NO error:error];
}

- (NSData*)dataFromNoteNamed:(NSString*)filename creatingIfMissing:(BOOL)create error:(NSError**)error {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return nil;
	int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW;
	if (create) flags |= O_CREAT;
	int fileDescriptor = openat(noteDirectoryFileDescriptor, name, flags, 0600);
	int openError = errno;
	free(name);
	if (fileDescriptor < 0) {
		if (error) *error = NVErrorFromErrno(openError, @"Open file", filename);
		return nil;
	}
	(void)fcntl(fileDescriptor, F_NOCACHE, 1);
	NSData *data = NVReadDataFromFileDescriptor(fileDescriptor, error);
	close(fileDescriptor);
	return data;
}

- (BOOL)_snapshotTagURL:(NSURL*)URL referencesFileDescriptor:(int)fileDescriptor {
	return NVURLReferencesFileDescriptor(URL, fileDescriptor);
}

- (id)_snapshotCocoaTagsAtURL:(NSURL*)URL {
	id tags = nil;
	return [URL getResourceValue:&tags forKey:NSURLTagNamesKey error:NULL] ? (tags ?: @[]) : nil;
}

- (BOOL)_setCocoaTags:(NSArray*)tags atURL:(NSURL*)URL error:(NSError**)error {
	return [URL setResourceValue:tags forKey:NSURLTagNamesKey error:error];
}

- (int)_statSnapshotName:(const char*)name status:(struct stat*)status {
	return fstatat(noteDirectoryFileDescriptor, name, status, AT_SYMLINK_NOFOLLOW);
}

- (void)_didInstallNoteFileNamed:(NSString*)filename {
	(void)filename; // Deterministic race-test seam; production has no work at this boundary.
}

- (void)_didSynchronizeTagsForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor {
	(void)filename;
	(void)fileDescriptor;
}

- (void)_didSetTextEncodingForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor {
	(void)filename;
	(void)fileDescriptor;
}

- (void)_didPrepareNoteFileNamed:(NSString*)filename { (void)filename; }

- (void)_didRejectAtomicSwapForNoteNamed:(NSString*)filename { (void)filename; }

- (void)_didExchangeNoteFileNamed:(NSString*)filename { (void)filename; }

- (int)_metadataFinalizationErrorAfterExchangingNoteNamed:(NSString*)filename {
	(void)filename;
	return 0;
}

- (void)_didObserveRenameCollisionFromName:(NSString*)oldName toName:(NSString*)newName {
	(void)oldName;
	(void)newName;
}

- (BOOL)_readNoteFileSnapshotOnce:(NVNoteFileSnapshot*)snapshot
				forNoteNamed:(NSString*)filename error:(NSError**)error {
	NSError *localError = nil;
	char *name = NULL;
	if (!snapshot) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Read note snapshot", filename);
		return NO;
	}
	if (!NVFileSystemName(filename, &name, &localError)) {
		if (error) *error = localError;
		return NO;
	}
	bzero(snapshot, sizeof(*snapshot));
	int fileDescriptor = openat(noteDirectoryFileDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	int openError = errno;
	if (fileDescriptor < 0) {
		free(name);
		if (error) *error = NVErrorFromErrno(openError, @"Open file", filename);
		return NO;
	}
	(void)fcntl(fileDescriptor, F_NOCACHE, 1);

	/*
	 * Theory of operation: all bytes and xattrs come from this descriptor, so a
	 * safe-save cannot splice fields from different vnodes.  Metadata brackets
	 * the reads, and the final fstatat proves that the directory name still names
	 * this vnode.  Generation count strengthens the comparison when a filesystem
	 * supplies it, but zero is explicitly invalid and therefore ignored.
	 */
	NVFileInfo before = { 0 }, after = { 0 };
	struct stat descriptorStatus = { 0 }, namedStatus = { 0 };
	BOOL succeeded = NVGetFileInfoFromDescriptor(fileDescriptor, &before, &localError);

	NSData *data = succeeded ? NVReadDataFromFileDescriptor(fileDescriptor, &localError) : nil;
	if (succeeded && !data) succeeded = NO;
	BOOL encodingPresent = NO;
	NSData *encodingData = data ? NVExtendedAttributeData(fileDescriptor,
		"com.apple.TextEncoding", &encodingPresent, &localError) : nil;
	if (data && !encodingData && encodingPresent) succeeded = NO;
	if (data && !encodingData && !encodingPresent && localError) succeeded = NO;
	NSStringEncoding encoding = 0;
	if (succeeded && encodingPresent && !NVParseTextEncoding(encodingData, &encoding, &localError)) succeeded = NO;

	NSArray *tags = nil;
	if (succeeded) {
		/* A file-reference URL is transient here; accept a valid Finder value,
		 * including an empty array, only after proving it names this FD. */
		NSURL *tagURL = [self fileReferenceURLForNoteNamed:filename error:NULL];
		NSArray *cocoaTags = NVSemanticTagNames(tagURL ?
			[self _snapshotCocoaTagsAtURL:tagURL] : nil);
		if (cocoaTags) {
			if ([self _snapshotTagURL:tagURL referencesFileDescriptor:fileDescriptor])
				tags = cocoaTags;
			else {
				localError = NVErrorFromErrno(EAGAIN, @"Read changing file", filename);
				succeeded = NO;
			}
		}
		else {
			BOOL tagsPresent = NO;
			NSData *tagsData = NVExtendedAttributeData(fileDescriptor,
				"com.apple.metadata:kMDItemOMUserTags", &tagsPresent, &localError);
			if (!tagsData && tagsPresent) succeeded = NO;
			if (!tagsData && !tagsPresent && localError) succeeded = NO;
			if (succeeded && tagsPresent && !(tags = NVParseTags(tagsData, &localError)))
				succeeded = NO;
		}
	}

	if (succeeded)
		succeeded = NVGetFileInfoFromDescriptor(fileDescriptor, &after, &localError) &&
			fstat(fileDescriptor, &descriptorStatus) == 0;
	if (!succeeded && !localError)
		localError = NVErrorFromErrno(errno, @"Inspect open file", filename);
	int namedResult = succeeded ? [self _statSnapshotName:name status:&namedStatus] : -1;
	close(fileDescriptor);
	free(name);
	if (!succeeded) {
		if (error) *error = localError;
		return NO;
	}

	BOOL stable = namedResult == 0 && S_ISREG(namedStatus.st_mode) &&
		descriptorStatus.st_dev == namedStatus.st_dev && descriptorStatus.st_ino == namedStatus.st_ino &&
		before.fileID == after.fileID && before.logicalSize == after.logicalSize &&
		[data length] == after.logicalSize &&
		NVTimespecEqual(before.attributeModificationTime, after.attributeModificationTime) &&
		(!before.generationCount || !after.generationCount ||
			before.generationCount == after.generationCount);
	if (!stable) {
		if (error) *error = NVErrorFromErrno(EAGAIN, @"Read changing file", filename);
		return NO;
	}
	snapshot->data = data;
	snapshot->tags = tags;
	snapshot->encoding = encoding;
	snapshot->info = after;
	return YES;
}

- (BOOL)readNoteFileSnapshot:(NVNoteFileSnapshot*)snapshot
				forNoteNamed:(NSString*)filename error:(NSError**)error {
	/* One immediate retry handles an ordinary safe-save without blocking the main thread. */
	if (!snapshot) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Read note snapshot", filename);
		return NO;
	}
	bzero(snapshot, sizeof(*snapshot));
	NSError *lastError = nil;
	for (NSUInteger attempt = 0; attempt < 2; attempt++) {
		NVNoteFileSnapshot candidate;
		lastError = nil;
		if ([self _readNoteFileSnapshotOnce:&candidate forNoteNamed:filename error:&lastError]) {
			*snapshot = candidate;
			return YES;
		}
		if (![[lastError domain] isEqualToString:NSPOSIXErrorDomain] || [lastError code] != EAGAIN)
			break;
	}
	if (error) *error = lastError;
	return NO;
}

- (BOOL)renameNoteFromName:(NSString*)oldName toName:(NSString*)newName error:(NSError**)error {
	char *oldFSName = NULL;
	char *newFSName = NULL;
	if (!NVFileSystemName(oldName, &oldFSName, error) ||
		!NVFileSystemName(newName, &newFSName, error)) {
		free(oldFSName);
		free(newFSName);
		return NO;
	}
	/* RENAME_EXCL is the atomic contract. A link/unlink emulation cannot safely
	 * roll back if either directory name changes concurrently. */
	int result = renameatx_np(noteDirectoryFileDescriptor, oldFSName,
		noteDirectoryFileDescriptor, newFSName, RENAME_EXCL);
	int renameError = errno;
	if (result < 0 && renameError == EEXIST) {
		[self _didObserveRenameCollisionFromName:oldName toName:newName];
		struct stat oldInfo;
		struct stat newInfo;
		if (fstatat(noteDirectoryFileDescriptor, oldFSName, &oldInfo, AT_SYMLINK_NOFOLLOW) < 0)
			renameError = errno;
		else if (fstatat(noteDirectoryFileDescriptor, newFSName, &newInfo, AT_SYMLINK_NOFOLLOW) < 0)
			renameError = errno;
		else if (oldInfo.st_dev == newInfo.st_dev && oldInfo.st_ino == newInfo.st_ino) {
			result = renameat(noteDirectoryFileDescriptor, oldFSName,
				noteDirectoryFileDescriptor, newFSName);
			if (result < 0) renameError = errno;
		}
	}
	if (result < 0) {
		if (renameError == ENOENT) {
			struct stat sourceInfo;
			if (fstatat(noteDirectoryFileDescriptor, oldFSName, &sourceInfo,
				AT_SYMLINK_NOFOLLOW) == 0)
				renameError = EAGAIN;
			else if (errno != ENOENT)
				renameError = errno;
		}
	}
	free(oldFSName);
	free(newFSName);
	if (result < 0) {
		if (error) *error = NVErrorFromErrno(renameError, @"Rename file", oldName);
		return NO;
	}
	return YES;
}

- (BOOL)getFileInfo:(NVFileInfo*)info forNoteNamed:(NSString*)filename error:(NSError**)error {
	if (!info) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Inspect file", filename);
		return NO;
	}
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return NO;
	BOOL succeeded = NVGetFileInfoAtDirectoryFileDescriptor(noteDirectoryFileDescriptor,
		name, info, error);
	free(name);
	return succeeded;
}

static struct timespec NVTimespecFromAbsoluteTime(CFAbsoluteTime time) {
	NSTimeInterval unixTime = time + kCFAbsoluteTimeIntervalSince1970;
	struct timespec result;
	result.tv_sec = (time_t)floor(unixTime);
	result.tv_nsec = (long)((unixTime - floor(unixTime)) * NSEC_PER_SEC);
	return result;
}

- (BOOL)setCreationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
				 forNoteNamed:(NSString*)filename error:(NSError**)error {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return NO;
	struct attrlist attributes;
	bzero(&attributes, sizeof(attributes));
	attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
	attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
	struct {
		struct timespec creation;
		struct timespec modification;
	} values = { NVTimespecFromAbsoluteTime(creationTime), NVTimespecFromAbsoluteTime(modificationTime) };
	int result = setattrlistat(noteDirectoryFileDescriptor, name, &attributes, &values, sizeof(values), 0);
	int setError = errno;
	free(name);
	if (result < 0) {
		if (error) *error = NVErrorFromErrno(setError, @"Set file dates", filename);
		return NO;
	}
	return YES;
}

static NSString *NVTextEncodingAttributeValue(NSStringEncoding encoding) {
	CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding);
	if (cfEncoding == kCFStringEncodingInvalidId) return nil;
	return [(NSString*)CFStringConvertEncodingToIANACharSetName(cfEncoding)
		stringByAppendingFormat:@";%u", (unsigned int)cfEncoding];
}

- (BOOL)setTextEncoding:(NSStringEncoding)encoding forNoteNamed:(NSString*)filename
	matchingFileInfo:(const NVFileInfo*)expectedInfo expectedData:(NSData*)expectedData
	resultingFileInfo:(NVFileInfo*)resultingInfo error:(NSError**)error {
	char *name = NULL;
	if (!expectedInfo || !resultingInfo || !NVFileSystemName(filename, &name, error)) return NO;
	int fd = openat(noteDirectoryFileDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	int openError = errno;
	if (fd < 0) {
		free(name);
		if (error) *error = NVErrorFromErrno(openError, @"Open file", filename);
		return NO;
	}
	NVFileInfo before = { 0 }, afterEncoding = { 0 }, after = { 0 };
	struct stat descriptorStatus = { 0 }, namedStatus = { 0 };
	BOOL matches = NVGetFileInfoFromDescriptor(fd, &before, error) &&
		before.fileID == expectedInfo->fileID && before.logicalSize == expectedInfo->logicalSize &&
		NVTimespecEqual(before.modificationTime, expectedInfo->modificationTime) &&
		NVTimespecEqual(before.attributeModificationTime, expectedInfo->attributeModificationTime) &&
		(!before.generationCount || !expectedInfo->generationCount ||
			before.generationCount == expectedInfo->generationCount);
	NSString *value = matches ? NVTextEncodingAttributeValue(encoding) : nil;
	const char *bytes = [value UTF8String];
	if (matches && !value) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Encode text encoding", filename);
		matches = NO;
	}
	if (matches && value && fsetxattr(fd, "com.apple.TextEncoding", bytes, strlen(bytes), 0, 0) < 0) {
		if (error) *error = NVErrorFromErrno(errno, @"Set text encoding", filename);
		matches = NO;
	}
	if (matches)
		matches = NVGetFileInfoFromDescriptor(fd, &afterEncoding, error) &&
			afterEncoding.fileID == before.fileID &&
			afterEncoding.logicalSize == before.logicalSize &&
			NVTimespecEqual(afterEncoding.modificationTime, before.modificationTime);
	if (matches) {
		[self _didSetTextEncodingForNoteNamed:filename fileDescriptor:fd];
		matches = NVDescriptorContainsStableData(fd, expectedData, &afterEncoding, &after, error);
	}
	if (matches)
		matches =
			fstat(fd, &descriptorStatus) == 0 &&
			fstatat(noteDirectoryFileDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
			descriptorStatus.st_dev == namedStatus.st_dev && descriptorStatus.st_ino == namedStatus.st_ino;
	close(fd);
	free(name);
	if (!matches) {
		if (error && !*error) *error = NVErrorFromErrno(EAGAIN, @"Reinterpret changing file", filename);
		return NO;
	}
	*resultingInfo = after;
	return YES;
}

- (BOOL)moveNoteToTrashNamed:(NSString*)filename resultingURL:(NSURL**)resultingURL error:(NSError**)error {
	NSURL *url = [self fileReferenceURLForNoteNamed:filename error:error];
	if (!url) return NO;
	NSURL *trashedURL = nil;
	BOOL result = [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:&trashedURL error:error];
	if (resultingURL) *resultingURL = result ? [trashedURL fileReferenceURL] : nil;
	return result;
}

- (BOOL)storeDataAtomicallyInNotesDirectory:(NSData*)data
										 withName:(NSString*)filename
							 verificationBlock:(NVFileVerificationBlock)verificationBlock
											error:(NSError**)error {
	return [self storeDataAtomicallyInNotesDirectory:data withName:filename
		preparationBlock:NULL verificationBlock:verificationBlock error:error];
}

/*
 * Theory of operation (full contract: docs/Atomic-Note-Saves.md): the
 * coordinator creates one hidden temporary file and
 * keeps its descriptor open throughout the transaction. Preparation writes and
 * validates all bytes and metadata before rename, swap, or link makes the file
 * visible. HFS+ exchange makes the prepared bytes visible first, then immediately
 * reapplies and syncs the prepared metadata on the installed vnode. Existing
 * destinations use replacement semantics; absent destinations use exclusive
 * creation semantics. ExFAT's last-resort create path is the exception: its
 * O_EXCL file is visible while it is populated. ExFAT conditional replacement
 * accepts a narrow race between its last content check and atomic rename.
 * After installation the directory is synced, the still-open installed descriptor
 * can be checked against the destination name, and the coordinator either
 * transfers that descriptor to its caller or cleans it up.
 * NVAtomicStore carries the shared names, descriptor, and recovery-cleanup state
 * through those phases; its pointers and descriptor are owned by the coordinator.
 */
typedef struct {
	int directoryFD, temporaryFD;
	char *destinationName, *temporaryName;
	NSString *filename, *temporaryFilename;
	BOOL removeTemporaryOnFailure;
} NVAtomicStore;

/* Fully prepare the hidden file and establish whether installation is a create
 * or replacement. No destination name is changed in this phase. */
static BOOL NVPrepareAtomicStore(NVAtomicStore *store, NSData *data, BOOL replaceExisting,
	NVFilePreparationBlock preparationBlock, NVFileVerificationBlock verificationBlock,
	NSData *expectedData, BOOL *destinationExists, NSError **error) {
	BOOL success = NVWriteDataToFileDescriptor(data, store->temporaryFD, error);
	if (success && verificationBlock) {
		NSData *readBack = NVReadDataFromFileDescriptor(store->temporaryFD, error);
		success = readBack && verificationBlock(readBack, error);
	}
	int destinationFD = success ? openat(store->directoryFD, store->destinationName,
		O_RDONLY | O_CLOEXEC | O_NOFOLLOW) : -1;
	*destinationExists = destinationFD >= 0;
	if (success && !*destinationExists && errno != ENOENT) {
		if (error) *error = NVErrorFromErrno(errno, @"Open destination", store->filename);
		success = NO;
	} else if (success && *destinationExists && !replaceExisting) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
			code:NSFileWriteFileExistsError userInfo:@{ NSFilePathErrorKey: store->filename }];
		success = NO;
	} else if (success && expectedData && !*destinationExists) {
		if (error) *error = NVErrorFromErrno(EAGAIN, @"Replace changing file", store->filename);
		success = NO;
	} else if (success && expectedData) {
		NSData *destinationData = NVReadDataFromFileDescriptor(destinationFD, NULL);
		if (![destinationData isEqualToData:expectedData]) {
			if (error) *error = NVErrorFromErrno(EAGAIN, @"Replace changing file", store->filename);
			success = NO;
		}
	}
	if (success && *destinationExists && replaceExisting) {
		struct stat temporaryInfo;
		struct timespec times[2];
		int statResult = fstat(store->temporaryFD, &temporaryInfo);
		if (statResult == 0) {
			times[0] = temporaryInfo.st_atimespec;
			times[1] = temporaryInfo.st_mtimespec;
		}
		if (statResult < 0 || fcopyfile(destinationFD, store->temporaryFD, NULL,
			COPYFILE_METADATA) < 0 || futimens(store->temporaryFD, times) < 0) {
			if (error) *error = NVErrorFromErrno(errno, @"Preserve destination metadata", store->filename);
			success = NO;
		}
	}
	if (destinationFD >= 0) close(destinationFD);
	if (success && preparationBlock && !preparationBlock(store->temporaryFD, error)) success = NO;
	if (success && fsync(store->temporaryFD) < 0) {
		if (error) *error = NVErrorFromErrno(errno, @"Synchronize temporary file", store->temporaryFilename);
		success = NO;
	}
	return success;
}

/* File descriptors are the stable identity proof used after path-based
 * installation and immediately before identity-sensitive cleanup. */
static BOOL NVFileDescriptorMatchesName(int fileDescriptor, int directoryFileDescriptor,
	const char *name) {
	struct stat descriptorStatus = { 0 }, namedStatus = { 0 };
	return fstat(fileDescriptor, &descriptorStatus) == 0 &&
		fstatat(directoryFileDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
		descriptorStatus.st_dev == namedStatus.st_dev && descriptorStatus.st_ino == namedStatus.st_ino;
}

static BOOL NVFileDescriptorsReferToSameFile(int firstFileDescriptor,
	int secondFileDescriptor) {
	struct stat firstStatus = { 0 }, secondStatus = { 0 };
	return fstat(firstFileDescriptor, &firstStatus) == 0 &&
		fstat(secondFileDescriptor, &secondStatus) == 0 &&
		firstStatus.st_dev == secondStatus.st_dev && firstStatus.st_ino == secondStatus.st_ino;
}

static BOOL NVAtomicReplacementCapabilityUnavailable(int errorNumber) {
	return errorNumber == ENOTSUP || errorNumber == EINVAL;
}

/* Move displaced bytes to a user-visible, exclusive recovery name. If that
 * cannot be done, leave the hidden temporary name in place for emergency recovery. */
static BOOL NVPreserveDisplacedAtomicFile(NVAtomicStore *store, NSError **error) {
	NSString *extension = [store->filename pathExtension];
	NSString *recoveryFilename = [NSString stringWithFormat:
		@"%@ (conflict recovery %@)%@%@", [store->filename stringByDeletingPathExtension],
		[[NSUUID UUID] UUIDString], [extension length] ? @"." : @"", extension];
	char *recoveryName = NULL;
	BOOL recovered = NVFileSystemName(recoveryFilename, &recoveryName, NULL) &&
		renameatx_np(store->directoryFD, store->temporaryName,
			store->directoryFD, recoveryName, RENAME_EXCL) == 0;
	free(recoveryName);
	(void)fsync(store->directoryFD);
	NSLog(@"Atomic replacement of '%@' required recovery. %@", store->filename, recovered ?
		[NSString stringWithFormat:@"Recovered displaced contents as '%@'", recoveryFilename] :
		@"Displaced contents remain in an emergency .nv-write file");
	store->removeTemporaryOnFailure = NO;
	if (error) *error = [NSError errorWithDomain:NVNoteStorageErrorDomain
		code:NVNoteStorageAtomicRecoveryError userInfo:@{ NSLocalizedDescriptionKey: recovered ?
			[NSString stringWithFormat:NSLocalizedString(
				@"a changing file's displaced contents were recovered as %@", nil), recoveryFilename] :
			NSLocalizedString(@"a changing file's displaced contents remain in emergency recovery storage", nil) }];
	return NO;
}

/* Recover the displaced file after exchange finalization fails. AtomicRecovery
 * means our replacement is still installed; EAGAIN keeps the local write pending
 * when its destination identity was lost. */
static BOOL NVRecoverFailedExchangedReplacement(NVAtomicStore *store,
	BOOL replacementStillInstalled, NSError **error) {
	(void)NVPreserveDisplacedAtomicFile(store,
		replacementStillInstalled ? error : NULL);
	if (!replacementStillInstalled && error)
		*error = NVErrorFromErrno(EAGAIN,
			@"Finish exchanged replacement", store->filename);
	return NO;
}

/* A successful swap or exchange leaves the previous destination at the
 * temporary name. Remove expected bytes; recover anything else. */
static BOOL NVFinishDisplacedAtomicFile(NVAtomicStore *store, int displacedFD,
	NSData *expectedData, NSError **error) {
	if (expectedData) {
		NSData *displacedData = displacedFD >= 0 ?
			NVReadDataFromFileDescriptor(displacedFD, NULL) : nil;
		if (![displacedData isEqualToData:expectedData])
			return NVPreserveDisplacedAtomicFile(store, error);
	}
	if (unlinkat(store->directoryFD, store->temporaryName, 0) < 0)
		NSLog(@"Unable to remove replaced file '%@': %s", store->temporaryFilename, strerror(errno));
	return YES;
}

/* copyfile preserves the portable metadata set. exchangedata() swaps HFS+
 * modification times but not creation times, so restore both prepared dates
 * from the pre-exchange snapshot. */
static int NVCopyPreparedAtomicMetadata(int sourceFD, int destinationFD,
	const NVFileInfo *preparedInfo) {
	struct attrlist attributes;
	bzero(&attributes, sizeof(attributes));
	attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
	attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
	struct {
		struct timespec creation;
		struct timespec modification;
	} dates = { preparedInfo->creationTime, preparedInfo->modificationTime };
	if (fcopyfile(sourceFD, destinationFD, NULL, COPYFILE_METADATA) < 0) return -1;
	return fsetattrlist(destinationFD, &attributes, &dates, sizeof(dates), 0);
}

/* exchangedata() makes open descriptors follow their swapped data. Reopen the
 * installed path, prove it is the prepared descriptor's new vnode, copy and sync
 * the prepared metadata, then hand that installed descriptor to the coordinator. */
static BOOL NVFinalizeExchangedAtomicReplacement(NVAtomicStore *store, int installedFD,
	NSData *expectedData, const NVFileInfo *preparedInfo,
	NotationController *controller, NSError **error) {
	int preparedFD = store->temporaryFD;
	int displacedFD = openat(store->directoryFD, store->temporaryName,
		O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	NSString *failedOperation = @"installed-file identity check";
	int finalizationError = 0;
	if (!NVFileDescriptorsReferToSameFile(preparedFD, installedFD) ||
		!NVFileDescriptorMatchesName(installedFD, store->directoryFD,
			store->destinationName))
		finalizationError = EAGAIN;
	if (!finalizationError && controller &&
		(finalizationError = [controller
			_metadataFinalizationErrorAfterExchangingNoteNamed:store->filename]))
		failedOperation = @"test-injected metadata finalization";
	if (!finalizationError && NVCopyPreparedAtomicMetadata(displacedFD,
		installedFD, preparedInfo) < 0) {
		failedOperation = @"metadata copy";
		finalizationError = errno;
	}
	if (!finalizationError && fsync(installedFD) < 0) {
		failedOperation = @"installed-file sync";
		finalizationError = errno;
	}
	if (finalizationError)
		NSLog(@"Unable to finish exchanged replacement of '%@' during %@: %s",
			store->filename, failedOperation, strerror(finalizationError));
	store->temporaryFD = installedFD;
	BOOL finished = finalizationError == 0;
	if (finished)
		finished = NVFinishDisplacedAtomicFile(store, displacedFD, expectedData, error);
	else {
		BOOL replacementStillInstalled =
			NVFileDescriptorsReferToSameFile(preparedFD, installedFD) &&
			NVFileDescriptorMatchesName(installedFD, store->directoryFD,
				store->destinationName);
		NVRecoverFailedExchangedReplacement(store,
			replacementStillInstalled, error);
	}
	if (displacedFD >= 0) close(displacedFD);
	close(preparedFD);
	return finished;
}

/* filesystems without swap or exchange get a last-second check and
 * atomic rename. A writer can still win between those operations; add a native
 * compare-and-swap primitive if the filesystem ever provides one. */
static BOOL NVInstallBestEffortConditionalReplacement(NVAtomicStore *store,
	NSData *expectedData, NSError **error) {
	int destinationFD = openat(store->directoryFD, store->destinationName,
		O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (destinationFD < 0) {
		if (error) *error = NVErrorFromErrno(errno, @"Recheck destination", store->filename);
		return NO;
	}
	NSData *destinationData = NVReadDataFromFileDescriptor(destinationFD, error);
	close(destinationFD);
	if (!destinationData) return NO;
	if (![destinationData isEqualToData:expectedData]) {
		if (error) *error = NVErrorFromErrno(EAGAIN, @"Replace changing file", store->filename);
		return NO;
	}
	if (renameat(store->directoryFD, store->temporaryName,
		store->directoryFD, store->destinationName) == 0) return YES;
	if (error) *error = NVErrorFromErrno(errno, @"Install replacement", store->filename);
	return NO;
}

/* Replace an existing name by descending a fixed capability ladder: APFS swap,
 * ordinary rename for unconditional stores, HFS+ exchange for conditional
 * stores, then the explicitly best-effort limited-filesystem fallback. */
static BOOL NVInstallAtomicReplacement(NVAtomicStore *store, NSData *expectedData,
	NotationController *controller, NSError **error) {
	if (renameatx_np(store->directoryFD, store->temporaryName,
		store->directoryFD, store->destinationName, RENAME_SWAP) == 0) {
		int displacedFD = expectedData ? openat(store->directoryFD, store->temporaryName,
			O_RDONLY | O_CLOEXEC | O_NOFOLLOW) : -1;
		BOOL finished = NVFinishDisplacedAtomicFile(store, displacedFD, expectedData, error);
		if (displacedFD >= 0) close(displacedFD);
		return finished;
	}
	int swapError = errno;
	if (!NVAtomicReplacementCapabilityUnavailable(swapError)) {
		if (error) *error = NVErrorFromErrno(swapError, @"Swap replacement", store->filename);
		return NO;
	}
	if (!expectedData) {
		if (renameat(store->directoryFD, store->temporaryName,
			store->directoryFD, store->destinationName) == 0) return YES;
		if (error) *error = NVErrorFromErrno(errno, @"Install replacement", store->filename);
		return NO;
	}

	NVFileInfo preparedInfo = { 0 };
	if (!NVGetFileInfoFromDescriptor(store->temporaryFD, &preparedInfo, error)) return NO;
	if (controller) [controller _didRejectAtomicSwapForNoteNamed:store->filename];
	if (NVExchangeDataAtDirectoryFileDescriptor(store->directoryFD,
		store->temporaryName, store->destinationName) == 0) {
		if (controller) [controller _didExchangeNoteFileNamed:store->filename];
		int installedFD = openat(store->directoryFD, store->destinationName,
			O_RDWR | O_CLOEXEC | O_NOFOLLOW);
		if (installedFD < 0) {
			NSLog(@"Unable to open exchanged replacement of '%@': %s",
				store->filename, strerror(errno));
			return NVRecoverFailedExchangedReplacement(store,
				NVFileDescriptorMatchesName(store->temporaryFD,
					store->directoryFD, store->destinationName), error);
		}
		return NVFinalizeExchangedAtomicReplacement(store, installedFD,
			expectedData, &preparedInfo, controller, error);
	}
	int exchangeError = errno;
	if (!NVAtomicReplacementCapabilityUnavailable(exchangeError)) {
		if (error) *error = NVErrorFromErrno(exchangeError, @"Exchange replacement", store->filename);
		return NO;
	}
	return NVInstallBestEffortConditionalReplacement(store, expectedData, error);
}

/* Install a previously absent name without overwriting a concurrent creator.
 * The fallbacks preserve O_EXCL behavior even where exclusive rename or links
 * are unavailable. */
static BOOL NVInstallNewAtomicFile(NVAtomicStore *store, NSData *data,
	NVFilePreparationBlock preparationBlock, NSError **error) {
	if (renameatx_np(store->directoryFD, store->temporaryName,
		store->directoryFD, store->destinationName, RENAME_EXCL) == 0) return YES;
	if (errno != ENOTSUP && errno != EINVAL) goto failed;
	if (linkat(store->directoryFD, store->temporaryName,
		store->directoryFD, store->destinationName, 0) == 0) {
		(void)unlinkat(store->directoryFD, store->temporaryName, 0);
		return YES;
	}
	if (errno != ENOTSUP && errno != EINVAL && errno != EPERM) goto failed;
	/* ExFAT has neither hard links nor exclusive rename. O_EXCL prevents overwrite,
	 * but readers may observe this last-resort file while it is populated. */
	int installedFD = openat(store->directoryFD, store->destinationName,
		O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (installedFD >= 0) {
		BOOL copied = NVWriteDataToFileDescriptor(data, installedFD, error);
		if (copied && preparationBlock && !preparationBlock(installedFD, error)) copied = NO;
		if (copied && fsync(installedFD) < 0) {
			if (error) *error = NVErrorFromErrno(errno, @"Synchronize new file", store->filename);
			copied = NO;
		}
		if (copied) {
			close(store->temporaryFD);
			store->temporaryFD = installedFD;
			(void)unlinkat(store->directoryFD, store->temporaryName, 0);
			return YES;
		}
		BOOL stillNamed = NVFileDescriptorMatchesName(installedFD,
			store->directoryFD, store->destinationName);
		close(installedFD);
		/* unlink follows the strongest identity proof ExFAT offers; a
		 * compare-and-unlink primitive would be needed to close the final race. */
		if (stillNamed) (void)unlinkat(store->directoryFD, store->destinationName, 0);
	}
failed:
	if (error && !*error) *error = NVErrorFromErrno(errno, @"Install new file", store->filename);
	return NO;
}

/* Prove that the retained descriptor is the vnode now named by the destination,
 * then return metadata read from that same descriptor. */
static BOOL NVInspectInstalledAtomicFile(NVAtomicStore *store,
	NVFileInfo *resultingFileInfo, NSError **error) {
	NVFileInfo info = { 0 };
	BOOL installed = NVGetFileInfoFromDescriptor(store->temporaryFD, &info, error) &&
		NVFileDescriptorMatchesName(store->temporaryFD, store->directoryFD, store->destinationName);
	if (installed) *resultingFileInfo = info;
	else if (error && !*error) *error = NVErrorFromErrno(EAGAIN, @"Inspect installed file", store->filename);
	return installed;
}

/* Coordinate prepare, exactly one install path, durability, identity checking,
 * and centralized cleanup/descriptor transfer. */
static BOOL NVStoreDataAtomicallyAtDirectoryFileDescriptor(int directoryFileDescriptor,
	NotationController *controller, NSData *data, NSString *filename, BOOL replaceExisting,
	NVFilePreparationBlock preparationBlock, NVFileVerificationBlock verificationBlock,
	NSData *expectedDestinationData,
	NVFileInfo *resultingFileInfo, int *resultingFileDescriptor, NSError **error) {
	if (!data) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Store data", filename);
		return NO;
	}
	NVAtomicStore store = { directoryFileDescriptor, -1, NULL, NULL, filename,
		[@".nv-write-" stringByAppendingString:[[NSUUID UUID] UUIDString]], YES };
	BOOL installed = NO, destinationExists = NO;
	if (!NVFileSystemName(filename, &store.destinationName, error) ||
		!NVFileSystemName(store.temporaryFilename, &store.temporaryName, error)) goto done;
	store.temporaryFD = openat(store.directoryFD, store.temporaryName,
		O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (store.temporaryFD < 0) {
		if (error) *error = NVErrorFromErrno(errno, @"Create temporary file", store.temporaryFilename);
		goto done;
	}
	installed = NVPrepareAtomicStore(&store, data, replaceExisting, preparationBlock,
		verificationBlock, expectedDestinationData, &destinationExists, error) &&
		(destinationExists ? NVInstallAtomicReplacement(&store, expectedDestinationData,
			controller, error) :
		 NVInstallNewAtomicFile(&store, data, preparationBlock, error));
	if (installed) (void)fsync(store.directoryFD);
	if (installed && resultingFileInfo)
		installed = NVInspectInstalledAtomicFile(&store, resultingFileInfo, error);
	if (!installed && store.removeTemporaryOnFailure && store.temporaryName)
		(void)unlinkat(store.directoryFD, store.temporaryName, 0);
	if (installed && resultingFileDescriptor) { *resultingFileDescriptor = store.temporaryFD; store.temporaryFD = -1; }
done:
	if (store.temporaryFD >= 0) close(store.temporaryFD);
	free(store.destinationName); free(store.temporaryName);
	return installed;
}

BOOL NVReplaceDataAtomicallyAtDirectoryFileDescriptor(int directoryFileDescriptor,
	NSData *data, NSString *filename, NSData *expectedData, NSError **error) {
	return NVStoreDataAtomicallyAtDirectoryFileDescriptor(directoryFileDescriptor,
		nil, data, filename, YES, NULL, NULL, expectedData, NULL, NULL, error);
}

- (BOOL)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename
	preparationBlock:(NVFilePreparationBlock)preparationBlock
	verificationBlock:(NVFileVerificationBlock)verificationBlock error:(NSError**)error {
	return NVStoreDataAtomicallyAtDirectoryFileDescriptor(noteDirectoryFileDescriptor,
		self, data, filename, YES, preparationBlock, verificationBlock, nil, NULL, NULL, error);
}

- (BOOL)createDataAtomicallyInNotesDirectory:(NSData*)data
	withName:(NSString*)filename error:(NSError**)error {
	return NVStoreDataAtomicallyAtDirectoryFileDescriptor(noteDirectoryFileDescriptor,
		self, data, filename, NO, NULL, NULL, nil, NULL, NULL, error);
}

- (BOOL)storeNoteDataAtomically:(NSData*)data withName:(NSString*)filename
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
	expectedData:(NSData*)expectedData
	resultingFileInfo:(NVFileInfo*)resultingFileInfo error:(NSError**)error {
	if (!resultingFileInfo) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Store note", filename);
		return NO;
	}
	NSData *tagData = [NSPropertyListSerialization dataWithPropertyList:(tags ? tags : @[])
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
	if (!tagData) return NO;
	NSString *encodingValue = encoding ? NVTextEncodingAttributeValue(encoding) : nil;
	if (encoding && !encodingValue) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Encode text encoding", filename);
		return NO;
	}
	NVFileInfo installedInfo = { 0 };
	int installedFD = -1;
	BOOL installed = NVStoreDataAtomicallyAtDirectoryFileDescriptor(noteDirectoryFileDescriptor,
		self, data, filename, YES, ^BOOL(int fd, NSError **blockError) {
			if (encoding) {
				const char *bytes = [encodingValue UTF8String];
				if (fsetxattr(fd, "com.apple.TextEncoding", bytes, strlen(bytes), 0, 0) < 0) {
					if (blockError) *blockError = NVErrorFromErrno(errno, @"Set text encoding", filename);
					return NO;
				}
			}
			if (fsetxattr(fd, "com.apple.metadata:kMDItemOMUserTags",
				[tagData bytes], [tagData length], 0, 0) < 0) {
				if (blockError) *blockError = NVErrorFromErrno(errno, @"Set file tags", filename);
				return NO;
			}
			struct attrlist attributes;
			bzero(&attributes, sizeof(attributes));
			attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
			attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
			struct {
				struct timespec creation;
				struct timespec modification;
			} values = { NVTimespecFromAbsoluteTime(creationTime),
				NVTimespecFromAbsoluteTime(modificationTime) };
			if (fsetattrlist(fd, &attributes, &values, sizeof(values), 0) < 0) {
				if (blockError) *blockError = NVErrorFromErrno(errno, @"Set file dates", filename);
				return NO;
			}
			[self _didPrepareNoteFileNamed:filename];
			return YES;
		}, NULL, expectedData, &installedInfo, &installedFD, error);
	if (!installed) return NO;
	[self _didInstallNoteFileNamed:filename];
	BOOL synchronized = NVSynchronizeOpenMetaAndCocoaTagsInternal(noteDirectoryFileDescriptor,
		installedFD, noteDirectoryURL, filename, tags ? tags : @[], &installedInfo,
		resultingFileInfo, data, YES, self, error);
	close(installedFD);
	return synchronized;
}

- (void)initializeFileMetadataVolumeUUID {
	if (currentFileMetadataVolumeUUID || [self currentNoteStorageFormat] == SingleDatabaseFormat) return;
	struct attrlist requested;
	bzero(&requested, sizeof(requested));
	requested.bitmapcount = ATTR_BIT_MAP_COUNT;
	requested.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID;
	struct {
		uint32_t length;
		uuid_t uuid;
	} attributes = { 0 };
	if (fgetattrlist(noteDirectoryFileDescriptor, &requested, &attributes, sizeof(attributes), 0) < 0)
		return;
	uuid_t zeroUUID = { 0 };
	if (!memcmp(attributes.uuid, zeroUUID, sizeof(zeroUUID))) return;
	NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:attributes.uuid];
	currentFileMetadataVolumeUUID = [[uuid UUIDString] copy];
	[uuid release];
}

- (BOOL)archivedFileMetadataIsForCurrentVolume {
	return currentFileMetadataVolumeUUID &&
		[currentFileMetadataVolumeUUID isEqualToString:[notationPrefs fileMetadataVolumeUUID]];
}

- (BOOL)notesDirectoryIsTrashed {
	NSURL *trashURL = [[NSFileManager defaultManager] URLForDirectory:NSTrashDirectory
		inDomain:NSUserDomainMask appropriateForURL:noteDirectoryURL create:NO error:NULL];
	return NVURLIsSameItemOrDescendantOfURL(noteDirectoryURL, trashURL);
}

- (BOOL)renameAndForgetNoteDatabaseFile:(NSString*)newfilename error:(NSError**)error {
	//this method does not move the note database file; for now it is used in cases of upgrading incompatible files
	if (![self renameNoteFromName:NotesDatabaseFileName toName:newfilename error:error]) {
		NSLog(@"Error renaming notes database file to %@: %@", newfilename, error ? *error : nil);
		return NO;
	}
	return YES;
}

- (BOOL)removeSpuriousDatabaseFileNotes {
	//remove any notes that might have been made out of the database or write-ahead-log files by accident
	//but leave the files intact; ensure only that they are also remotely unsynced
	//returns true if at least one note was removed, in which case allNotes should probably be refiltered
	
	NSUInteger i = 0;
	NoteObject *dbNote = nil, *walNote = nil;
	
	for (i=0; i<[allNotes count]; i++) {
		NoteObject *obj = [allNotes objectAtIndex:i];
		
		if (!dbNote && [filenameOfNote(obj) isEqualToString:NotesDatabaseFileName])
			dbNote = [[obj retain] autorelease];
		if (!walNote && [filenameOfNote(obj) isEqualToString:@"Interim Note-Changes"])
			walNote = [[obj retain] autorelease];
	}
	if (dbNote) {
		[allNotes removeObjectIdenticalTo:dbNote];
		[self _addDeletedNote:dbNote];
	}
	if (walNote) {
		[allNotes removeObjectIdenticalTo:walNote];
		[self _addDeletedNote:walNote];
	}
	return walNote || dbNote;
}

- (void)relocateNotesDirectory {
	
	while (1) {
		NSOpenPanel *openPanel = [NSOpenPanel openPanel];
		[openPanel setCanCreateDirectories:YES];
		[openPanel setCanChooseFiles:NO];
		[openPanel setCanChooseDirectories:YES];
		[openPanel setResolvesAliases:YES];
		[openPanel setAllowsMultipleSelection:NO];
		[openPanel setTreatsFilePackagesAsDirectories:NO];
		[openPanel setTitle:NSLocalizedString(@"Select a folder",nil)];
		[openPanel setPrompt:NSLocalizedString(@"Select",nil)];
		[openPanel setMessage:NSLocalizedString(@"Select a new location for your Notational Velocity notes.",nil)];
		
		if ([openPanel runModal] == NSModalResponseOK) {
			NSURL *selectedURL = [[NSFileManager defaultManager] fileReferenceURLForURL:[openPanel URL] error:NULL];
			if (selectedURL) {
				NSString *directoryName = nil;
				[noteDirectoryURL getResourceValue:&directoryName forKey:NSURLNameKey error:NULL];
				const char *name = [directoryName fileSystemRepresentation];
				int oldParentFD = openat(noteDirectoryFileDescriptor, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
				int newParentFD = [[NSFileManager defaultManager]
					openFileDescriptorForDirectoryReferenceURL:selectedURL error:NULL];
				if (!name || oldParentFD < 0 || newParentFD < 0) {
					if (oldParentFD >= 0) close(oldParentFD);
					if (newParentFD >= 0) close(newParentFD);
					NSAlert *alert = [[[NSAlert alloc] init] autorelease];
					[alert setMessageText:NSLocalizedString(@"Unable to access the chosen directory.", nil)];
					[alert setInformativeText:NSLocalizedString(@"Your notes were not moved.", nil)];
					[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
					[alert runModal];
					continue;
				}

				
				int moveResult = renameatx_np(oldParentFD, name, newParentFD, name, RENAME_EXCL);
				int moveError = errno;
				close(oldParentFD);
				close(newParentFD);
				if (moveResult < 0) {
					NSString *messageText = [NSString stringWithFormat:NSLocalizedString(@"Couldn't move notes into the chosen folder because %@", nil),
						[NSError errorWithDomain:NSPOSIXErrorDomain code:moveError userInfo:nil]];
					NSAlert *alert = [[[NSAlert alloc] init] autorelease];
					[alert setMessageText:messageText];
					[alert setInformativeText:NSLocalizedString(@"Your notes were not moved.", nil)];
					[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
					[alert runModal];
					continue;
				}
				
				[[GlobalPrefs defaultPrefs] setDefaultDirectoryURL:noteDirectoryURL sender:self error:NULL];
				[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ noteDirectoryURL ]];
				goto terminate;
			} else {
				goto terminate;
			}
		} else {
terminate:
			[NSApp terminate:nil];
			break;
		}
	}
}

//whenever a note uses this method to change its filename, we will have to re-establish all the links to it
- (NSString*)uniqueFilenameForTitle:(NSString*)title fromNote:(NoteObject*)note {
    //generate a unique filename based on title, varying numbers
    BOOL isUnique = YES;
    NSString *uniqueFilename = title;
	
	NSMutableString *sanitizedName = [[uniqueFilename mutableCopy] autorelease];
	[sanitizedName replaceOccurrencesOfString:@"/" withString:@":" options:0
		range:NSMakeRange(0, [sanitizedName length])];
	if ([sanitizedName length] && [sanitizedName characterAtIndex:0] == (unichar)'.')
		[sanitizedName replaceCharactersInRange:NSMakeRange(0, 1) withString:@"_"];
	uniqueFilename = [[sanitizedName copy] autorelease];
	
	//use the note's current format if the current default format is for a database; get the "ideal" extension for that format
	int noteFormat = [notationPrefs notesStorageFormat] || !note ? [notationPrefs notesStorageFormat] : storageFormatOfNote(note);
	NSString *extension = [notationPrefs chosenPathExtensionForFormat:noteFormat];
	
	//if the note's current extension is compatible with the storage format above, then use the existing extension instead
	if (note && filenameOfNote(note) && [notationPrefs pathExtensionAllowed:[filenameOfNote(note) pathExtension] forFormat:noteFormat])
		extension = [filenameOfNote(note) pathExtension];
	
	//assume that we won't have more than 999 notes with the exact same name and of more than 247 chars
    uniqueFilename = [uniqueFilename filenameExpectingAdditionalCharCount:(int)(3 + [extension length] + 2)];
	
    unsigned int iteration = 0;
	do {
		isUnique = YES;
		
		//this ought to just use an nsset, but then we'd have to maintain a parallel data structure for marginal benefit
		//also, it won't quite work right for filenames with no (real) extensions and periods in their names
		for (NoteObject *aNote in allNotes) {
			NSString *basefilename = [filenameOfNote(aNote) stringByDeletingPathExtension];
			
			if (note != aNote && [basefilename caseInsensitiveCompare:uniqueFilename] == NSOrderedSame) {
				isUnique = NO;
				
				uniqueFilename = [uniqueFilename stringByDeletingPathExtension];
				NSString *numberPath = [@((int)++iteration) stringValue];
				uniqueFilename = [uniqueFilename stringByAppendingPathExtension:numberPath];
				break;
			}
		}
		//catch filename collisions with untracked files in the notes directory
		NSString *candidate = [uniqueFilename stringByAppendingPathExtension:extension];
		struct stat candidateInfo;
		BOOL databaseDestinationExists = note && storageFormatOfNote(note) == SingleDatabaseFormat &&
			fstatat(noteDirectoryFileDescriptor, [candidate fileSystemRepresentation],
				&candidateInfo, AT_SYMLINK_NOFOLLOW) == 0;
		if (isUnique && !databaseDestinationExists &&
			(!note || ![candidate isEqualToString:filenameOfNote(note)]) &&
			NVCaseInsensitiveNameExists(noteDirectoryFileDescriptor, candidate,
				note ? filenameOfNote(note) : nil)) {
			isUnique = NO;
			uniqueFilename = [uniqueFilename stringByDeletingPathExtension];
			uniqueFilename = [uniqueFilename stringByAppendingPathExtension:
				[@((int)++iteration) stringValue]];
		}
    } while (!isUnique);
	
    return [uniqueFilename stringByAppendingPathExtension:extension];
}

@end
