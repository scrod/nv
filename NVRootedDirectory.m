//
//  NVRootedDirectory.m
//  Notation
//
//  Created by Zachary Schneirov on 8/16/26.

/*Copyright (c) 2026, Zachary Schneirov. All rights reserved.
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

#import "NVRootedDirectory.h"
#import "NVRootedDirectory_Private.h"
#if NV_INTEGRATION_TESTING
#import "tests/NVRootedDirectoryTestHooks.h"
#else
#define NVTemporaryFilenameForWrite(hooks, filename) \
	[@".nv-write-" stringByAppendingString:[[NSUUID UUID] UUIDString]]
#define NVRenameFileExclusivelyForWrite(hooks, filename, oldFD, oldName, newFD, newName) \
	renameatx_np(oldFD, oldName, newFD, newName, RENAME_EXCL)
#define NVUnlinkTemporaryForWrite(hooks, filename, directoryFD, name) \
	unlinkat(directoryFD, name, 0)
#define NVGetExtendedAttributeForSnapshot(hooks, fileDescriptor, name, value, size, readingValue) \
	fgetxattr(fileDescriptor, name, value, size, 0, 0)
#endif
#import "NSFileManager_NV.h"
#import "BufferUtils.h"
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <sys/xattr.h>
#include <unistd.h>

int NVBarrierSyncFileDescriptor(int fileDescriptor) {
	int result;
	do result = fcntl(fileDescriptor, F_BARRIERFSYNC, 0);
	while (result < 0 && errno == EINTR);
	if (result >= 0) return 0;
	int barrierError = errno;
	if (barrierError != ENOTSUP && barrierError != EINVAL &&
		barrierError != ENODEV && barrierError != ENOTTY) return -1;
	do result = fsync(fileDescriptor); while (result < 0 && errno == EINTR);
	return result;
}

static NSError *NVRootedDirectoryError(int errorNumber, NSString *operation, NSString *filename) {
	NSString *description = filename ?
		[NSString stringWithFormat:@"%@ '%@': %s", operation, filename, strerror(errorNumber)] :
		[NSString stringWithFormat:@"%@: %s", operation, strerror(errorNumber)];
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errorNumber
		userInfo:[NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey]];
}

static BOOL NVRootedLeafFileSystemName(NSString *filename, char **name, NSError **error) {
	int nameError = NVCopyFileSystemNameForLeaf(filename, name);
	if (nameError && error) *error = NVRootedDirectoryError(nameError, @"Validate filename", filename);
	return nameError == 0;
}

#define NVDirectoryOpenFlags (O_RDONLY | O_DIRECTORY | O_CLOEXEC)

static int NVDirectoryDescriptorFailure(NSError **error, NSError *value) {
	if (error) *error = value;
	return -1;
}

/* Opens a directory when its full path is longer than open() accepts.
 * It walks from the filesystem root and opens the path in shorter pieces.
 * Requires: URL resolves to an absolute directory path.
 * On success: returns a directory descriptor that the caller must close.
 * On failure: closes intermediate descriptors and reports the error. */
static int NVOpenDeepDirectoryReferenceURL(NSURL *URL, NSError **error) {
	CFIndex capacity = PATH_MAX;
	UInt8 *path = NULL;
	for (; capacity <= LONG_MAX / 2; capacity *= 2) {
		path = reallocf(path, (size_t)capacity);
		if (!path) return NVDirectoryDescriptorFailure(error,
			NVRootedDirectoryError(ENOMEM, @"Allocate resolved directory path", nil));
		if (CFURLGetFileSystemRepresentation((CFURLRef)URL, true, path, capacity)) break;
	}
	if (capacity > LONG_MAX / 2 || path[0] != '/') {
		free(path);
		return NVDirectoryDescriptorFailure(error,
			NVRootedDirectoryError(ENAMETOOLONG, @"Resolve deep directory reference", nil));
	}

	int directoryFD = open("/", NVDirectoryOpenFlags);
	int openError = errno;
	for (char *component = (char *)path + 1; directoryFD >= 0 && *component;) {
		char *end = component + MIN(strlen(component), PATH_MAX - 1);
		while (end > component && *end && *end != '/') end--;
		if (end == component) {
			close(directoryFD);
			directoryFD = -1;
			openError = ENAMETOOLONG;
			break;
		}
		char separator = *end;
		*end = '\0';
		int childFD = openat(directoryFD, component, NVDirectoryOpenFlags);
		openError = errno;
		*end = separator;
		close(directoryFD);
		directoryFD = childFD;
		component = end;
		while (*component == '/') component++;
	}
	free(path);
	return directoryFD >= 0 ? directoryFD : NVDirectoryDescriptorFailure(error,
		NVRootedDirectoryError(openError, @"Open deep directory reference", nil));
}

/* Opens a file-reference URL, which follows a directory when it is renamed.
 * It refreshes stale URL data and handles paths longer than PATH_MAX.
 * Requires: URL is a directory file-reference URL.
 * On success: returns a directory descriptor that the caller must close.
 * On failure: leaves no descriptor open and reports the error. */
static int NVOpenDirectoryReferenceURL(NSURL *URL, NSError **error) {
	if (![URL isFileReferenceURL]) return NVDirectoryDescriptorFailure(error,
		NVRootedDirectoryError(EINVAL, @"Open non-reference directory URL", nil));
	const char *path = [URL fileSystemRepresentation];
	int directoryFD = path ? open(path, NVDirectoryOpenFlags) : -1;
	if (directoryFD >= 0) return directoryFD;
	int openError = path ? errno : ENAMETOOLONG;
	if (openError == ENOENT) {
		[URL removeAllCachedResourceValues];
		path = [URL fileSystemRepresentation];
		directoryFD = path ? open(path, NVDirectoryOpenFlags) : -1;
		if (directoryFD >= 0) return directoryFD;
		openError = path ? errno : ENAMETOOLONG;
	}
	return openError == ENAMETOOLONG ? NVOpenDeepDirectoryReferenceURL(URL, error) :
		NVDirectoryDescriptorFailure(error,
			NVRootedDirectoryError(openError, @"Open directory reference", nil));
}

NSComparisonResult NVCompareTimespecs(struct timespec one, struct timespec two) {
	if (one.tv_sec != two.tv_sec)
		return one.tv_sec < two.tv_sec ? NSOrderedAscending : NSOrderedDescending;
	if (one.tv_nsec != two.tv_nsec)
		return one.tv_nsec < two.tv_nsec ? NSOrderedAscending : NSOrderedDescending;
	return NSOrderedSame;
}

CFAbsoluteTime NVAbsoluteTimeFromTimespec(struct timespec value) {
	return (CFAbsoluteTime)value.tv_sec + ((CFAbsoluteTime)value.tv_nsec / NSEC_PER_SEC) -
		kCFAbsoluteTimeIntervalSince1970;
}

struct timespec NVTimespecFromAbsoluteTime(CFAbsoluteTime time) {
	NSTimeInterval unixTime = time + kCFAbsoluteTimeIntervalSince1970;
	struct timespec result = { (time_t)floor(unixTime),
		(long)((unixTime - floor(unixTime)) * NSEC_PER_SEC) };
	return result;
}

static BOOL NVObservationsHaveSameContentRevision(NVFileObservation *one,
	NVFileObservation *two) {
	return one && two && [one logicalSize] == [two logicalSize] &&
		NVCompareTimespecs([one modificationTime], [two modificationTime]) == NSOrderedSame;
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
} NVRootedFileAttributes;

_Static_assert(offsetof(NVRootedFileAttributes, returned) == 4, "returned attribute offset");
_Static_assert(offsetof(NVRootedFileAttributes, objectType) == 24, "object type attribute offset");
_Static_assert(offsetof(NVRootedFileAttributes, creationTime) == 28, "creation time attribute offset");
_Static_assert(offsetof(NVRootedFileAttributes, generationCount) == 76, "generation count attribute offset");
_Static_assert(offsetof(NVRootedFileAttributes, fileID) == 84, "file ID attribute offset");
_Static_assert(offsetof(NVRootedFileAttributes, logicalSize) == 92, "logical size attribute offset");

static struct attrlist NVRootedFileAttributeRequest(void) {
	struct attrlist requested;
	bzero(&requested, sizeof(requested));
	requested.bitmapcount = ATTR_BIT_MAP_COUNT;
	requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME |
		ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_GEN_COUNT |
		ATTR_CMN_DOCUMENT_ID | ATTR_CMN_FILEID;
	requested.fileattr = ATTR_FILE_DATALENGTH;
	return requested;
}

/* Reads the file's size, timestamps, and stable identifiers.
 * Together these values describe the observed version of the file. */
static NVFileObservation *NVObservationFromFileDescriptor(int fileDescriptor, NSError **error) {
	struct attrlist requested = NVRootedFileAttributeRequest();
	NVRootedFileAttributes attributes = { 0 };
	int result = fgetattrlist(fileDescriptor, &requested, &attributes, sizeof(attributes),
		FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS);
	int statusError = errno;
	const attrgroup_t required = ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME |
		ATTR_CMN_CHGTIME | ATTR_CMN_FILEID;
	if (result < 0 || attributes.length < sizeof(attributes) || attributes.objectType != VREG ||
		(attributes.returned.commonattr & required) != required ||
		!(attributes.returned.fileattr & ATTR_FILE_DATALENGTH) || attributes.logicalSize < 0) {
		if (error) *error = NVRootedDirectoryError(result < 0 ? statusError : EINVAL,
			@"Inspect file", nil);
		return nil;
	}
	return [[[NVFileObservation alloc] initWithCreationTime:attributes.creationTime
		modificationTime:attributes.modificationTime
		attributeModificationTime:attributes.changeTime
		logicalSize:(uint64_t)attributes.logicalSize fileID:attributes.fileID
		documentID:(attributes.returned.commonattr & ATTR_CMN_DOCUMENT_ID) ? attributes.documentID : 0
		generationCount:(attributes.returned.commonattr & ATTR_CMN_GEN_COUNT) ? attributes.generationCount : 0]
		autorelease];
}

/* Reads every byte from a regular file with pread(), which uses explicit offsets.
 * The descriptor's shared read position therefore stays unchanged. */
static NSData *NVDataFromFileDescriptor(int fileDescriptor, NSError **error) {
	struct stat status;
	if (fstat(fileDescriptor, &status) < 0) {
		if (error) *error = NVRootedDirectoryError(errno, @"Inspect file", nil);
		return nil;
	}
	if (!S_ISREG(status.st_mode) || status.st_size < 0 || (uint64_t)status.st_size > NSUIntegerMax) {
		if (error) *error = NVRootedDirectoryError(EINVAL, @"Read non-regular file", nil);
		return nil;
	}
	NSMutableData *result = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
	uint8_t *bytes = [result mutableBytes];
	size_t remaining = (size_t)status.st_size;
	off_t offset = 0;
	while (remaining) {
		ssize_t amount = pread(fileDescriptor, bytes + offset, remaining, offset);
		if (amount < 0 && errno == EINTR) continue;
		if (amount <= 0) {
			if (error) *error = NVRootedDirectoryError(amount < 0 ? errno : EIO, @"Read file", nil);
			return nil;
		}
		offset += amount;
		remaining -= (size_t)amount;
	}
	return result;
}

@implementation NVFileObservation

@synthesize creationTime, modificationTime, attributeModificationTime;
@synthesize logicalSize, fileID, documentID, generationCount;

/* Stores one unchanging set of file timestamps, size, and identifiers.
 * Callers use the complete set to detect replacement or modification.
 * Requires: all values describe the same observed file state.
 * On success: the receiver owns that complete observation. */
- (id)initWithCreationTime:(struct timespec)creation
	modificationTime:(struct timespec)modification
	attributeModificationTime:(struct timespec)attributeModification
	logicalSize:(uint64_t)size fileID:(uint64_t)identifier
	documentID:(uint32_t)documentIdentifier generationCount:(uint32_t)generation {
	self = [super init];
	if (self) {
		creationTime = creation;
		modificationTime = modification;
		attributeModificationTime = attributeModification;
		logicalSize = size;
		fileID = identifier;
		documentID = documentIdentifier;
		generationCount = generation;
	}
	return self;
}

- (id)copyWithZone:(NSZone*)zone { return [self retain]; }

- (BOOL)hasSameIdentityAndRevisionAsObservation:(NVFileObservation*)other {
	return other && logicalSize == [other logicalSize] && fileID == [other fileID] &&
		NVCompareTimespecs(modificationTime, [other modificationTime]) == NSOrderedSame &&
		NVCompareTimespecs(attributeModificationTime,
			[other attributeModificationTime]) == NSOrderedSame &&
		(!generationCount || ![other generationCount] || generationCount == [other generationCount]);
}

@end


@implementation NVFileSnapshot

@synthesize data, tags, encoding, observation;

/* Captures exact file bytes together with tags, encoding, and an observation.
 * The observation records which file version supplied the other values.
 * Requires: fileData and fileObservation are non-nil.
 * On success: the snapshot owns its copied data, tags, and observation. */
- (id)initWithData:(NSData*)fileData tags:(NSArray*)fileTags
	encoding:(NSStringEncoding)textEncoding observation:(NVFileObservation*)fileObservation {
	if (!fileData || !fileObservation) {
		[self release];
		return nil;
	}
	self = [super init];
	if (self) {
		data = [fileData copy];
		tags = [fileTags copy];
		encoding = textEncoding;
		observation = [fileObservation retain];
	}
	return self;
}

- (void)dealloc {
	[data release];
	[tags release];
	[observation release];
	[super dealloc];
}

@end


@implementation NVFileWriteResult

@synthesize disposition, capability, installedSnapshot, error, recoveryFilename;

/* Records whether a write was installed, how safely it was installed, and any error.
 * It rejects combinations that could give callers a misleading result.
 * Requires: the disposition, snapshot, and error agree as asserted below.
 * On success: the result owns the supplied snapshot, error, and recovery name. */
- (id)initWithDisposition:(NVFileWriteDisposition)aDisposition
	capability:(NVFileWriteCapability)aCapability installedSnapshot:(NVFileSnapshot*)snapshot
	error:(NSError*)writeError
	recoveryFilename:(NSString*)filename {
	NSParameterAssert(aDisposition <= NVFileWriteInstalledNeedsReconciliation);
	NSParameterAssert(aCapability <= NVFileWriteBestEffortCapability);
	NSParameterAssert((aDisposition == NVFileWriteInstalledVerified) ==
		(snapshot != nil && writeError == nil));
	NSParameterAssert(aDisposition != NVFileWriteNotInstalled ||
		(snapshot == nil && filename == nil && writeError != nil));
	self = [super init];
	if (self) {
		disposition = aDisposition;
		capability = aCapability;
		installedSnapshot = [snapshot retain];
		error = [writeError retain];
		recoveryFilename = [filename copy];
	}
	return self;
}

- (void)dealloc {
	[installedSnapshot release];
	[error release];
	[recoveryFilename release];
	[super dealloc];
}

@end


typedef NS_ENUM(NSUInteger, NVRootedWriteIntent) {
	NVRootedWriteCreate,
	NVRootedWriteConditionalReplace,
	NVRootedWriteOverwrite
};

typedef BOOL (^NVRootedFilePreparationBlock)(int fileDescriptor, NSError **error);
typedef BOOL (^NVRootedFileFinalizationBlock)(int fileDescriptor, NSError **error);

/* Working state for one call to _writeFileNamed:. This struct lives only on that
 * method's stack and is passed to the helpers that prepare, install, and clean up a write.
 *
 * New bytes are first written to preparedFD under temporaryName. Installation then
 * renames, swaps, links, or copies that file to destinationName. preparedFD keeps
 * following the new data as names change. After a swap, temporaryName instead names
 * the old destination, which can be checked, deleted, or preserved for recovery.
 *
 * Installation can become visible before later verification or cleanup fails. The two
 * state flags preserve that distinction so the final NVFileWriteResult never reports
 * "not installed" after this transaction changed the destination. capability records
 * the filesystem tier selected, and recoveryFilename records any leaf worth inspecting.
 *
 * The root owns directoryFD, and the surrounding method owns the Objective-C strings.
 * This transaction owns preparedFD and the allocated C-string names. The common finish
 * block closes and frees them on every return; NVFileWriteResult copies recoveryFilename. */
typedef struct {
	/* Rooted directory in which every filename operation is performed. Borrowed. */
	int directoryFD;
	/* When nonnegative, open file that follows new data through installation. Owned. */
	int preparedFD;
	/* When non-NULL, allocated C-string for the final leaf. A leaf contains no path. */
	char *destinationName;
	/* When non-NULL, allocated staging leaf, or the displaced old file after a swap. */
	char *temporaryName;
	/* Objective-C form of destinationName, borrowed for errors and test callbacks. */
	NSString *filename;
	/* Objective-C form of temporaryName, borrowed for errors and recovery reports. */
	NSString *temporaryFilename;
	/* YES once data from this write has become visible at the destination name. */
	BOOL namespaceInstalled;
	/* YES when visible leftovers or uncertainty require the caller to rescan and reconcile. */
	BOOL reconciliationRequired;
	/* Guarantee provided by the selected install path: atomic, HFS-compatible, or best effort. */
	NVFileWriteCapability capability;
	/* Optional borrowed leaf to inspect for retained data; the result object copies it. */
	NSString *recoveryFilename;
} NVRootedAtomicStore;

static NSInteger NVCompareCatalogEntryName(const void *one, const void *two) {
	NoteCatalogEntry *first = *(NoteCatalogEntry **)one;
	NoteCatalogEntry *second = *(NoteCatalogEntry **)two;
	return (NSInteger)CFStringCompare(first->filename, second->filename,
		kCFCompareCaseInsensitive);
}

@implementation NVRootedDirectoryCatalog

- (NoteCatalogEntry*)entries { return entries; }
- (NoteCatalogEntry**)sortedEntries { return sortedEntries; }
- (size_t)count { return count; }

/* Adds a filename and its identity fields to the catalog's compact arrays.
 * The arrays grow together so each entry keeps one stable storage slot.
 * Requires: filename carries one retain that this method may consume.
 * On return: the catalog owns filename on success and releases it on failure. */
- (BOOL)appendOwnedFilename:(CFStringRef)filename
	attributeChangeTime:(struct timespec)changeTime documentID:(uint32_t)documentID
	fileID:(uint64_t)fileID generationCount:(uint32_t)generationCount {
	if (count == capacity) {
		size_t oldCapacity = capacity;
		size_t newCapacity = MAX((size_t)32, oldCapacity * 2);
		NoteCatalogEntry **newSortedEntries = realloc(sortedEntries,
			newCapacity * sizeof(*sortedEntries));
		if (!newSortedEntries) { CFRelease(filename); return NO; }
		sortedEntries = newSortedEntries;
		NoteCatalogEntry *newEntries = realloc(entries, newCapacity * sizeof(*entries));
		if (!newEntries) { CFRelease(filename); return NO; }
		entries = newEntries;
		bzero(entries + oldCapacity, (newCapacity - oldCapacity) * sizeof(*entries));
		capacity = newCapacity;
	}
	NoteCatalogEntry *entry = &entries[count];
	entry->filename = filename;
	entry->attributeChangeTime = changeTime;
	entry->documentID = documentID;
	entry->fileID = fileID;
	entry->generationCount = generationCount;
	sortedEntries[count++] = entry;
	return YES;
}

- (void)sortCaseInsensitively {
	for (size_t index = 0; index < count; index++)
		sortedEntries[index] = &entries[index];
	if (count > 1)
		mergesort(sortedEntries, count, sizeof(*sortedEntries),
			(int (*)(const void *, const void *))NVCompareCatalogEntryName);
}

/* Reports equality only when every filename, timestamp, and identifier matches.
 * It sorts pointer indexes for comparison without moving the stored entries.
 * On return: entry storage is unchanged, but both pointer indexes may be reordered. */
- (BOOL)isExactlyEqualToCatalog:(NVRootedDirectoryCatalog*)other {
	if (!other || count != [other count]) return NO;
	[self sortCaseInsensitively];
	[other sortCaseInsensitively];
	NoteCatalogEntry **otherEntries = [other sortedEntries];
	for (size_t index = 0; index < count; index++) {
		NoteCatalogEntry *one = sortedEntries[index], *two = otherEntries[index];
		if (!CFEqual(one->filename, two->filename) ||
			NVCompareTimespecs(one->attributeChangeTime,
				two->attributeChangeTime) != NSOrderedSame ||
			one->fileID != two->fileID || one->documentID != two->documentID ||
			one->generationCount != two->generationCount) return NO;
	}
	return YES;
}

- (void)dealloc {
	for (size_t index = 0; index < count; index++)
		if (entries[index].filename) CFRelease(entries[index].filename);
	free(entries);
	free(sortedEntries);
	[super dealloc];
}

@end

typedef struct __attribute__((packed, aligned(4))) {
	uint32_t length;
	attribute_set_t returned;
	uint32_t error;
	attrreference_t name;
	fsobj_type_t objectType;
	struct timespec changeTime;
	uint32_t generationCount;
	uint32_t documentID;
	uint64_t fileID;
} NVRootedBulkCatalogRecord;

_Static_assert(offsetof(NVRootedBulkCatalogRecord, returned) == 4, "returned attribute offset");
_Static_assert(offsetof(NVRootedBulkCatalogRecord, error) == 24, "error attribute offset");
_Static_assert(offsetof(NVRootedBulkCatalogRecord, name) == 28, "name attribute offset");
_Static_assert(offsetof(NVRootedBulkCatalogRecord, objectType) == 36, "object type attribute offset");
_Static_assert(offsetof(NVRootedBulkCatalogRecord, changeTime) == 40, "change time attribute offset");
_Static_assert(offsetof(NVRootedBulkCatalogRecord, generationCount) == 56, "generation count attribute offset");
_Static_assert(offsetof(NVRootedBulkCatalogRecord, documentID) == 60, "document ID attribute offset");
_Static_assert(offsetof(NVRootedBulkCatalogRecord, fileID) == 64, "file ID attribute offset");

/* Parses one variable-length record returned by getattrlistbulk().
 * It checks all sizes, offsets, types, and names before returning field pointers.
 * Requires: bytes contains availableLength readable bytes.
 * On return: output pointers are filled only for fields the result makes usable. */
NVBulkCatalogParseResult NVParseBulkCatalogRecord(const void *bytes, size_t availableLength,
	size_t *parsedRecordLength, const char **name, size_t *nameLength, struct timespec *changeTime,
	uint32_t *documentID, uint64_t *fileID, uint32_t *generationCount) {
	if (!bytes || availableLength < sizeof(uint32_t)) return NVBulkCatalogRecordMalformed;
	const NVRootedBulkCatalogRecord *record = bytes;
	uint32_t length = 0;
	memcpy(&length, &record->length, sizeof(length));
	if (length < sizeof(*record) || length > availableLength) return NVBulkCatalogRecordMalformed;
	if (parsedRecordLength) *parsedRecordLength = length;
	if (!(record->returned.commonattr & ATTR_CMN_ERROR)) return NVBulkCatalogRecordUnsupported;
	uint32_t entryError = 0;
	memcpy(&entryError, &record->error, sizeof(entryError));
	if (entryError)
		return entryError == ENOENT ? NVBulkCatalogRecordTransient : NVBulkCatalogRecordUnsupported;
	const attrgroup_t mandatory = ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_CHGTIME | ATTR_CMN_FILEID;
	if ((record->returned.commonattr & mandatory) != mandatory)
		return NVBulkCatalogRecordUnsupported;
	fsobj_type_t objectType = VNON;
	memcpy(&objectType, &record->objectType, sizeof(objectType));
	if (objectType != VREG) return NVBulkCatalogRecordSkipped;
	attrreference_t nameReference;
	memcpy(&nameReference, &record->name, sizeof(nameReference));
	if (nameReference.attr_length <= 1 || nameReference.attr_dataoffset < 0)
		return NVBulkCatalogRecordMalformed;
	size_t nameOffset = offsetof(NVRootedBulkCatalogRecord, name) +
		(size_t)nameReference.attr_dataoffset;
	if (nameOffset < sizeof(*record) || nameOffset > length ||
		nameReference.attr_length > length - nameOffset)
		return NVBulkCatalogRecordMalformed;
	const char *recordName = (const char *)bytes + nameOffset;
	if (recordName[nameReference.attr_length - 1] != '\0' ||
		memchr(recordName, '\0', nameReference.attr_length - 1))
		return NVBulkCatalogRecordMalformed;
	if (name) *name = recordName;
	if (nameLength) *nameLength = nameReference.attr_length - 1;
	if (changeTime) memcpy(changeTime, &record->changeTime, sizeof(*changeTime));
	if (fileID) memcpy(fileID, &record->fileID, sizeof(*fileID));
	if (generationCount) *generationCount =
		(record->returned.commonattr & ATTR_CMN_GEN_COUNT) ? record->generationCount : 0;
	if (documentID) *documentID = (record->returned.commonattr & ATTR_CMN_DOCUMENT_ID) ?
		record->documentID : 0;
	return NVBulkCatalogRecordFile;
}

@interface NVRootedDirectory () {
@private
	NSURL *fileReferenceURL;
	NSData *bookmarkData;
	int directoryFileDescriptor;
}
- (NVFileWriteResult*)_writeFileNamed:(NSString*)filename data:(NSData*)data
	intent:(NVRootedWriteIntent)intent expectedSnapshot:(NVFileSnapshot*)expectedSnapshot
	preparation:(NVRootedFilePreparationBlock)preparation
	preparedDataVerifier:(NVRootedFileVerificationBlock)verifier
	finalization:(NVRootedFileFinalizationBlock)finalization
	installedSnapshotTags:(NSArray*)tags encoding:(NSStringEncoding)encoding;
- (NVRootedDirectoryCatalog*)_newFoundationCatalog:(NSError**)error;
- (BOOL)_removeFileNamed:(NSString*)filename
	ifMatchingObservation:(NVFileObservation*)expected error:(NSError**)error;
@end

/* Repeats write() until every byte is written or a real error occurs.
 * Interrupted writes are retried, while short writes continue with the remaining bytes.
 * Requires: fileDescriptor is writable.
 * On success: all bytes have been written; on failure, a prefix may have been. */
static BOOL NVWriteDataToDescriptor(NSData *data, int fileDescriptor, NSError **error) {
	const uint8_t *bytes = [data bytes];
	size_t remaining = [data length];
	while (remaining) {
		ssize_t amount = write(fileDescriptor, bytes, remaining);
		if (amount < 0 && errno == EINTR) continue;
		if (amount <= 0) {
			if (error) *error = NVRootedDirectoryError(amount < 0 ? errno : EIO, @"Write file", nil);
			return NO;
		}
		bytes += amount;
		remaining -= (size_t)amount;
	}
	return YES;
}

static BOOL NVDescriptorMatchesName(int fileDescriptor, int directoryFileDescriptor,
	const char *name) {
	struct stat descriptorStatus = { 0 }, namedStatus = { 0 };
	return fstat(fileDescriptor, &descriptorStatus) == 0 &&
		fstatat(directoryFileDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
		descriptorStatus.st_dev == namedStatus.st_dev && descriptorStatus.st_ino == namedStatus.st_ino;
}

static BOOL NVDescriptorsReferToSameFile(int firstFileDescriptor, int secondFileDescriptor) {
	struct stat firstStatus = { 0 }, secondStatus = { 0 };
	return fstat(firstFileDescriptor, &firstStatus) == 0 &&
		fstat(secondFileDescriptor, &secondStatus) == 0 &&
		firstStatus.st_dev == secondStatus.st_dev && firstStatus.st_ino == secondStatus.st_ino;
}

static NSURL *NVDescriptorURL(int fileDescriptor) {
	return [NSURL fileURLWithPath:[NSString stringWithFormat:@"/dev/fd/%d", fileDescriptor]];
}

static BOOL NVDescriptorReferencesURL(int fileDescriptor, NSURL *URL) {
	if (fileDescriptor < 0 || !URL) return NO;
	if (NVURLsReferToSameItem(NVDescriptorURL(fileDescriptor), URL)) return YES;
	struct stat descriptorStatus = { 0 }, URLStatus = { 0 };
	const char *path = [URL fileSystemRepresentation];
	return path && fstat(fileDescriptor, &descriptorStatus) == 0 && stat(path, &URLStatus) == 0 &&
		descriptorStatus.st_dev == URLStatus.st_dev && descriptorStatus.st_ino == URLStatus.st_ino;
}

static BOOL NVAtomicPrimitiveUnavailable(int errorNumber) {
	return errorNumber == ENOTSUP || errorNumber == EINVAL;
}

/* Tries to rename one leaf, meaning one filename without a directory path.
 * It first uses an exclusive rename that cannot replace an existing destination.
 * Requires: both names are valid leaves relative to directoryFD.
 * On success: sourceName is now destinationName. On the fallback path, another
 * process can still create destinationName between the check and rename. */
static int NVRenameExclusivelyWithinDirectory(int directoryFD,
	const char *sourceName, const char *destinationName) {
	if (renameatx_np(directoryFD, sourceName, directoryFD,
		destinationName, RENAME_EXCL) == 0) return 0;
	int renameError = errno;
	if (!NVAtomicPrimitiveUnavailable(renameError)) return -1;
	struct stat destinationStatus;
	if (fstatat(directoryFD, destinationName, &destinationStatus,
		AT_SYMLINK_NOFOLLOW) == 0) {
		errno = EEXIST;
		return -1;
	}
	if (errno != ENOENT) return -1;
	return renameat(directoryFD, sourceName, directoryFD, destinationName);
}

/* Uses HFS+ exchangedata() to swap file contents while keeping both names.
 * Open descriptors follow their original contents to the opposite name.
 * Requires: both descriptors still match their names in the rooted directory.
 * On return: namespaceInstalled says whether an exchange already took place. */
static int NVExchangeDataForHFSCompatibility(NVRootedAtomicStore *store) {
	int destinationFD = openat(store->directoryFD, store->destinationName,
		O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (destinationFD < 0) return -1;
	if (!NVDescriptorMatchesName(store->preparedFD, store->directoryFD, store->temporaryName) ||
		!NVDescriptorMatchesName(destinationFD, store->directoryFD, store->destinationName)) {
		close(destinationFD);
		errno = EAGAIN;
		return -1;
	}
	char directoryPath[PATH_MAX];
	if (fcntl(store->directoryFD, F_GETPATH, directoryPath) < 0) {
		close(destinationFD);
		return -1;
	}
	size_t directoryLength = strlen(directoryPath);
	size_t temporaryLength = strlen(store->temporaryName);
	size_t destinationLength = strlen(store->destinationName);
	if (directoryLength + 1 + MAX(temporaryLength, destinationLength) + 1 > PATH_MAX) {
		close(destinationFD);
		errno = ENAMETOOLONG;
		return -1;
	}
	char temporaryPath[PATH_MAX], destinationPath[PATH_MAX];
	memcpy(temporaryPath, directoryPath, directoryLength);
	temporaryPath[directoryLength] = '/';
	memcpy(temporaryPath + directoryLength + 1, store->temporaryName, temporaryLength + 1);
	memcpy(destinationPath, directoryPath, directoryLength);
	destinationPath[directoryLength] = '/';
	memcpy(destinationPath + directoryLength + 1, store->destinationName, destinationLength + 1);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	int result = exchangedata(temporaryPath, destinationPath, FSOPT_NOFOLLOW_ANY | FSOPT_UNIQUE);
#pragma clang diagnostic pop
	int exchangeError = errno;
	if (result == 0) {
		store->namespaceInstalled = YES;
		store->capability = NVFileWriteHFSCompatibilityCapability;
	}
	/* exchangedata(2) keeps namespace object identifiers in place while open
	 * descriptors follow their original data to the opposite name. */
	if (result == 0 && (!NVDescriptorMatchesName(store->preparedFD, store->directoryFD,
		store->destinationName) || !NVDescriptorMatchesName(destinationFD,
		store->directoryFD, store->temporaryName))) {
		result = -1;
		exchangeError = EAGAIN;
	}
	close(destinationFD);
	errno = exchangeError;
	return result;
}

/* Sets the creation date and last-modified date on one already-open file.
 * Using the descriptor avoids looking the file up again by a changeable path.
 * Requires: fileDescriptor permits attribute changes.
 * On success: both creation and modification dates have been applied. */
static int NVSetDescriptorDates(int fileDescriptor, struct timespec creation,
	struct timespec modification) {
	struct attrlist attributes;
	bzero(&attributes, sizeof(attributes));
	attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
	attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
	struct {
		struct timespec creation;
		struct timespec modification;
	} dates = { creation, modification };
	return fsetattrlist(fileDescriptor, &attributes, &dates, sizeof(dates), 0);
}

static BOOL NVCopyPreparedMetadata(int sourceFD, int destinationFD,
	NVFileObservation *preparedObservation) {
	return fcopyfile(sourceFD, destinationFD, NULL, COPYFILE_METADATA) == 0 &&
		NVSetDescriptorDates(destinationFD, [preparedObservation creationTime],
			[preparedObservation modificationTime]) == 0;
}

/* Preserves the old destination when it differs from the version we expected.
 * That old file was "displaced" to the temporary name during an atomic swap.
 * Requires: temporaryName identifies the displaced file after installation.
 * On return: reconciliation is required and recoveryFilename records where to look. */
static BOOL NVPreserveDisplacedFile(NVRootedAtomicStore *store, NSError **error) {
	NSString *extension = [store->filename pathExtension];
	NSString *recoveryFilename = [NSString stringWithFormat:
		@"%@ (conflict recovery %@)%@%@", [store->filename stringByDeletingPathExtension],
		[[NSUUID UUID] UUIDString], [extension length] ? @"." : @"", extension];
	char *recoveryName = NULL;
	BOOL recovered = NVRootedLeafFileSystemName(recoveryFilename, &recoveryName, NULL) &&
		renameatx_np(store->directoryFD, store->temporaryName,
			store->directoryFD, recoveryName, RENAME_EXCL) == 0;
	free(recoveryName);
	store->reconciliationRequired = YES;
	store->recoveryFilename = recovered ? recoveryFilename : store->temporaryFilename;
	if (error) *error = NVRootedDirectoryError(EAGAIN, recovered ?
		@"Recover displaced file" : @"Retain emergency displaced file", store->recoveryFilename);
	return NO;
}

/* Removes a temporary filename only after proving it still names our open file.
 * This prevents a concurrent replacement from being deleted by mistake.
 * Requires: fileDescriptor is the owned temporary file, or is negative when none exists.
 * On success: that temporary name is absent or no owned temporary file existed.
 * On failure: an installed write is marked for reconciliation and retained if possible. */
static BOOL NVRemoveTemporaryFile(NVRootedAtomicStore *store, int fileDescriptor,
	id hooks, NSError **error) {
	if (fileDescriptor < 0 || !store->temporaryName) return YES;
	if (!NVDescriptorMatchesName(fileDescriptor, store->directoryFD, store->temporaryName)) {
		struct stat namedStatus;
		if (fstatat(store->directoryFD, store->temporaryName,
			&namedStatus, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT) return YES;
		if (store->namespaceInstalled) store->reconciliationRequired = YES;
		if (error) *error = NVRootedDirectoryError(EAGAIN,
			@"Remove changing temporary file", store->temporaryFilename);
		return NO;
	}
	int removeResult = NVUnlinkTemporaryForWrite(hooks, store->filename,
		store->directoryFD, store->temporaryName);
	int removeError = errno;
	if (removeResult == 0 || removeError == ENOENT) return YES;
	if (store->namespaceInstalled) {
		store->reconciliationRequired = YES;
		store->recoveryFilename = store->temporaryFilename;
	}
	if (error) *error = NVRootedDirectoryError(removeError,
		@"Remove temporary file", store->temporaryFilename);
	return NO;
}

/* Checks the old destination, which an atomic swap moved to the temporary name.
 * Expected old data is deleted; unexpected data is kept for conflict recovery.
 * Requires: temporaryName should hold the file displaced by an installed replacement.
 * On success: the expected displaced file is gone; conflicts are retained on failure. */
static BOOL NVFinishDisplacedFile(NVRootedAtomicStore *store,
	NSData *expectedData, NSError **error) {
	int displacedFD = openat(store->directoryFD, store->temporaryName,
		O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	int openError = errno;
	if (displacedFD < 0) {
		if (!expectedData && openError == ENOENT) return YES;
		store->reconciliationRequired = YES;
		if (error) *error = NVRootedDirectoryError(openError,
			@"Verify displaced file", store->temporaryFilename);
		return NO;
	}
	NSData *displacedData = expectedData ? NVDataFromFileDescriptor(displacedFD, NULL) : nil;
	BOOL expectedMatches = !expectedData || [displacedData isEqualToData:expectedData];
	if (!expectedMatches) {
		BOOL stillNamed = NVDescriptorMatchesName(displacedFD,
			store->directoryFD, store->temporaryName);
		close(displacedFD);
		if (stillNamed) return NVPreserveDisplacedFile(store, error);
		store->reconciliationRequired = YES;
		if (error) *error = NVRootedDirectoryError(EAGAIN,
			@"Recover displaced changing file", store->filename);
		return NO;
	}
	BOOL removed = NVRemoveTemporaryFile(store, displacedFD, nil, error);
	close(displacedFD);
	return removed;
}

/* Builds the private "staging" file that will later become the destination.
 * It writes and verifies data, copies metadata, runs preparation, and issues a write barrier.
 * Requires: preparedFD is a new file owned by store.
 * On success: destinationExists reports the check and the staging file is ready to install.
 * On failure: the staging file remains owned by store for cleanup. */
static BOOL NVPrepareAtomicStore(NVRootedAtomicStore *store, NSData *data,
	NVRootedWriteIntent intent, NSData *expectedData,
	NVRootedFilePreparationBlock preparation, NVRootedFileVerificationBlock verifier,
	BOOL *destinationExists, NSError **error) {
	BOOL success = NVWriteDataToDescriptor(data, store->preparedFD, error);
	if (success && verifier) {
		NSData *readBack = NVDataFromFileDescriptor(store->preparedFD, error);
		success = readBack && verifier(readBack, error);
	}
	int destinationFD = success ? openat(store->directoryFD, store->destinationName,
		O_RDONLY | O_CLOEXEC | O_NOFOLLOW) : -1;
	int destinationError = errno;
	*destinationExists = destinationFD >= 0;
	if (success && !*destinationExists && destinationError != ENOENT) {
		if (error) *error = NVRootedDirectoryError(destinationError, @"Open destination", store->filename);
		success = NO;
	} else if (success && *destinationExists && intent == NVRootedWriteCreate) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
			code:NSFileWriteFileExistsError userInfo:@{ NSFilePathErrorKey: store->filename }];
		success = NO;
	} else if (success && !*destinationExists && intent == NVRootedWriteConditionalReplace) {
		if (error) *error = NVRootedDirectoryError(EAGAIN, @"Replace changing file", store->filename);
		success = NO;
	} else if (success && expectedData) {
		NSData *destinationData = NVDataFromFileDescriptor(destinationFD, NULL);
		if (![destinationData isEqualToData:expectedData]) {
			if (error) *error = NVRootedDirectoryError(EAGAIN, @"Replace changing file", store->filename);
			success = NO;
		}
	}
	if (success && *destinationExists && intent != NVRootedWriteCreate) {
		struct stat temporaryInfo;
		struct timespec times[2];
		int statResult = fstat(store->preparedFD, &temporaryInfo);
		if (statResult == 0) {
			times[0] = temporaryInfo.st_atimespec;
			times[1] = temporaryInfo.st_mtimespec;
		}
		if (statResult < 0 || fcopyfile(destinationFD, store->preparedFD, NULL,
			COPYFILE_METADATA) < 0 || futimens(store->preparedFD, times) < 0) {
			if (error) *error = NVRootedDirectoryError(errno, @"Preserve destination metadata", store->filename);
			success = NO;
		}
	}
	if (destinationFD >= 0) close(destinationFD);
	if (success && preparation && !preparation(store->preparedFD, error)) success = NO;
	if (success && NVBarrierSyncFileDescriptor(store->preparedFD) < 0) {
		if (error) *error = NVRootedDirectoryError(errno, @"Synchronize prepared file", store->temporaryFilename);
		success = NO;
	}
	return success;
}

/* Rechecks the expected old bytes, then replaces the destination with rename().
 * This fallback is best effort because the check and rename are separate operations.
 * Requires: the prepared file is complete; expectedData, when present, is the expected old data.
 * On success: the prepared file has the destination name, but another writer could
 * have changed the destination after the check. */
static BOOL NVInstallBestEffortReplacement(NVRootedAtomicStore *store,
	NSData *expectedData, NSError **error) {
	store->capability = NVFileWriteBestEffortCapability;
	if (expectedData) {
		int destinationFD = openat(store->directoryFD, store->destinationName,
			O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
		if (destinationFD < 0) {
			if (error) *error = NVRootedDirectoryError(errno,
				@"Recheck destination", store->filename);
			return NO;
		}
		NSData *destinationData = NVDataFromFileDescriptor(destinationFD, error);
		close(destinationFD);
		if (!destinationData || ![destinationData isEqualToData:expectedData]) {
			if (destinationData && error) *error = NVRootedDirectoryError(EAGAIN,
				@"Replace changing file", store->filename);
			return NO;
		}
	}
	if (renameat(store->directoryFD, store->temporaryName,
		store->directoryFD, store->destinationName) < 0) {
		if (error) *error = NVRootedDirectoryError(errno, @"Install replacement", store->filename);
		return NO;
	}
	store->namespaceInstalled = YES;
	return YES;
}

/* Installs staged data by trying atomic swap, HFS+ exchange, then ordinary rename.
 * An atomic operation makes the name change indivisible to concurrent observers.
 * Requires: preparedFD is complete and destinationName exists.
 * On return: namespaceInstalled records whether new data reached the destination name. */
static BOOL NVInstallReplacement(NVRootedAtomicStore *store, NSData *expectedData,
	id hooks, NSError **error) {
	if (renameatx_np(store->directoryFD, store->temporaryName,
		store->directoryFD, store->destinationName, RENAME_SWAP) == 0) {
		store->namespaceInstalled = YES;
		return NVFinishDisplacedFile(store, expectedData, error);
	}
	int swapError = errno;
	if (!NVAtomicPrimitiveUnavailable(swapError)) {
		if (error) *error = NVRootedDirectoryError(swapError, @"Swap replacement", store->filename);
		return NO;
	}
	NVFileObservation *preparedObservation = NVObservationFromFileDescriptor(store->preparedFD, error);
	if (!preparedObservation) return NO;
	#if NV_INTEGRATION_TESTING
	if ([hooks respondsToSelector:@selector(_didRejectAtomicSwapForNoteNamed:)])
		[hooks _didRejectAtomicSwapForNoteNamed:store->filename];
	#endif
	if (NVExchangeDataForHFSCompatibility(store) == 0) {
		#if NV_INTEGRATION_TESTING
		if ([hooks respondsToSelector:@selector(_didExchangeNoteFileNamed:)])
			[hooks _didExchangeNoteFileNamed:store->filename];
		#endif
		int installedFD = openat(store->directoryFD, store->destinationName,
			O_RDWR | O_CLOEXEC | O_NOFOLLOW);
		int displacedFD = openat(store->directoryFD, store->temporaryName,
			O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
		int finalizationError = 0;
		if (installedFD < 0 || displacedFD < 0 ||
			!NVDescriptorsReferToSameFile(store->preparedFD, installedFD) ||
			!NVDescriptorMatchesName(displacedFD, store->directoryFD, store->temporaryName) ||
			!NVDescriptorMatchesName(installedFD, store->directoryFD, store->destinationName))
			finalizationError = EAGAIN;
		#if NV_INTEGRATION_TESTING
		if (!finalizationError && [hooks respondsToSelector:
			@selector(_metadataFinalizationErrorAfterExchangingNoteNamed:)])
			finalizationError = [hooks _metadataFinalizationErrorAfterExchangingNoteNamed:store->filename];
		#endif
		if (!finalizationError && !NVCopyPreparedMetadata(displacedFD, installedFD, preparedObservation))
			finalizationError = errno;
		if (!finalizationError && fsync(installedFD) < 0) finalizationError = errno;
		int originalPreparedFD = store->preparedFD;
		if (installedFD >= 0) store->preparedFD = installedFD;
		BOOL finished = finalizationError == 0 &&
			NVFinishDisplacedFile(store, expectedData, error);
		if (finalizationError) {
			store->reconciliationRequired = YES;
			NVPreserveDisplacedFile(store, error);
		}
		if (displacedFD >= 0) close(displacedFD);
		close(originalPreparedFD);
		if (installedFD < 0) store->preparedFD = -1;
		return finished;
	}
	int exchangeError = errno;
	if (!NVAtomicPrimitiveUnavailable(exchangeError)) {
		if (store->namespaceInstalled)
			NVPreserveDisplacedFile(store, error);
		else if (error) *error = NVRootedDirectoryError(exchangeError, @"Exchange replacement", store->filename);
		return NO;
	}
	return NVInstallBestEffortReplacement(store, expectedData, error);
}

/* Creates a previously absent destination with the strongest available operation.
 * It tries exclusive rename, hard-link installation, then direct creation.
 * Requires: the staging file is complete and the destination was observed absent.
 * On return: the flags say whether the destination changed and whether callers must rescan. */
static BOOL NVInstallNewFile(NVRootedAtomicStore *store, NSData *data,
	NVRootedFilePreparationBlock preparation, id hooks, NSError **error) {
	int exclusiveResult = NVRenameFileExclusivelyForWrite(hooks, store->filename,
		store->directoryFD, store->temporaryName,
		store->directoryFD, store->destinationName);
	if (exclusiveResult == 0) {
		store->namespaceInstalled = YES;
		return YES;
	}
	if (!NVAtomicPrimitiveUnavailable(errno)) goto failed;
	if (linkat(store->directoryFD, store->temporaryName,
		store->directoryFD, store->destinationName, 0) == 0) {
		store->namespaceInstalled = YES;
		store->capability = NVFileWriteHFSCompatibilityCapability;
		return NVRemoveTemporaryFile(store, store->preparedFD, hooks, error);
	}
	if (errno != ENOTSUP && errno != EINVAL && errno != EPERM) goto failed;
	/* ExFAT cannot install an absent name atomically. O_EXCL prevents overwrite,
	 * and the result explicitly reports this best-effort capability. */
	int installedFD = openat(store->directoryFD, store->destinationName,
		O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (installedFD >= 0) {
		store->namespaceInstalled = YES;
		store->capability = NVFileWriteBestEffortCapability;
		BOOL copied = NVWriteDataToDescriptor(data, installedFD, error);
		if (copied && preparation && !preparation(installedFD, error)) copied = NO;
		if (copied && fsync(installedFD) < 0) {
			if (error) *error = NVRootedDirectoryError(errno, @"Synchronize new file", store->filename);
			copied = NO;
		}
		if (copied) {
			BOOL removed = NVRemoveTemporaryFile(store, store->preparedFD, hooks, error);
			close(store->preparedFD);
			store->preparedFD = installedFD;
			return removed;
		}
		BOOL stillNamed = NVDescriptorMatchesName(installedFD,
			store->directoryFD, store->destinationName);
		close(installedFD);
		if (stillNamed && unlinkat(store->directoryFD, store->destinationName, 0) < 0 &&
			errno != ENOENT) {
			store->reconciliationRequired = YES;
			store->recoveryFilename = store->temporaryFilename;
			if (error) *error = NVRootedDirectoryError(errno,
				@"Remove incomplete installed file", store->filename);
			return NO;
		}
		store->namespaceInstalled = NO;
	}
failed:
	if (error && !*error) *error = NVRootedDirectoryError(errno, @"Install new file", store->filename);
	return NO;
}

/* Reads one extended attribute, a named metadata value stored with the file.
 * It detects if the value's size changes between measuring and reading it.
 * On success: present distinguishes an absent attribute from an empty value. */
static NSData *NVExtendedAttributeDataFromDescriptor(int fileDescriptor, const char *name,
	id hooks, BOOL *present, NSError **error) {
	if (present) *present = NO;
	ssize_t length = NVGetExtendedAttributeForSnapshot(hooks,
		fileDescriptor, name, NULL, 0, NO);
	if (length < 0) {
		if (errno == ENOATTR) return nil;
		if (error) *error = NVRootedDirectoryError(errno, @"Read extended attribute", nil);
		return nil;
	}
	NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
	ssize_t actualLength = NVGetExtendedAttributeForSnapshot(hooks, fileDescriptor, name,
		[data mutableBytes], [data length], YES);
	if (actualLength < 0) {
		if (error) *error = NVRootedDirectoryError(errno == ERANGE || errno == ENOATTR ? EAGAIN : errno,
			@"Read extended attribute", nil);
		return nil;
	}
	[data setLength:(NSUInteger)actualLength];
	if (present) *present = YES;
	return data;
}

/* Converts Finder tags to their visible names by removing encoded color suffixes.
 * A suffix is a newline plus a color digit; tag order and empty names are preserved. */
NSArray *NVSemanticTagNames(NSArray *tags) {
	if (![tags isKindOfClass:[NSArray class]]) return nil;
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:[tags count]];
	for (id value in tags) {
		if (![value isKindOfClass:[NSString class]]) return nil;
		NSString *tag = value;
		NSUInteger length = [tag length];
		if (length >= 2 && [tag characterAtIndex:length - 2] == '\n' &&
			[tag characterAtIndex:length - 1] >= '0' && [tag characterAtIndex:length - 1] <= '7')
			[names addObject:[tag substringToIndex:length - 2]];
		else [names addObject:tag];
	}
	return names;
}

/* Reads an installed file and observes it again after reading the bytes.
 * It returns a snapshot only if the same unchanged file supplied the whole result. */
static NVFileSnapshot *NVSnapshotFromInstalledDescriptor(int fileDescriptor, NSData *expectedData,
	NSArray *knownTags, NSStringEncoding knownEncoding, NSError **error) {
	NVFileObservation *before = NVObservationFromFileDescriptor(fileDescriptor, error);
	NSData *data = before ? NVDataFromFileDescriptor(fileDescriptor, error) : nil;
	if (!data || (expectedData && ![data isEqualToData:expectedData])) {
		if (data && error) *error = NVRootedDirectoryError(EAGAIN, @"Verify installed contents", nil);
		return nil;
	}
	NVFileObservation *after = NVObservationFromFileDescriptor(fileDescriptor, error);
	if (!after || ![before hasSameIdentityAndRevisionAsObservation:after] ||
		[data length] != [after logicalSize]) {
		if (after && error) *error = NVRootedDirectoryError(EAGAIN, @"Verify installed file", nil);
		return nil;
	}
	return [[[NVFileSnapshot alloc] initWithData:data tags:knownTags
		encoding:knownEncoding observation:after] autorelease];
}

@implementation NVRootedDirectory

/* Creates a rooted capability: an open directory used as the authority for later access.
 * It also saves a bookmark, a persistent reference that can find a renamed directory.
 * Requires: URL is a live directory file-reference URL.
 * On success: the root owns its descriptor, URL, and bookmark.
 * On failure: any descriptor opened here is closed. */
- (id)initWithFileReferenceURL:(NSURL*)URL error:(NSError**)error {
	NSFileManager *manager = [NSFileManager defaultManager];
	int fileDescriptor = NVOpenDirectoryReferenceURL(URL, error);
	if (fileDescriptor < 0) {
		[self release];
		return nil;
	}
	NSError *bookmarkError = nil;
	NSData *data = [manager bookmarkDataForFileReferenceURL:URL error:&bookmarkError];
	if (!data) {
		close(fileDescriptor);
		if (error) *error = bookmarkError;
		[self release];
		return nil;
	}
	return [self initWithOwnedDirectoryFileDescriptor:fileDescriptor
		fileReferenceURL:URL bookmarkData:data error:error];
}

/* Resolves a saved bookmark, opens that directory, and rebuilds the rooted capability.
 * A stale bookmark still resolves but is replaced with current bookmark data when possible.
 * Requires: data is bookmark data for a directory.
 * On success: the root owns the opened directory and the freshest available bookmark.
 * On failure: any descriptor opened here is closed. */
- (id)initWithBookmarkData:(NSData*)data error:(NSError**)error {
	BOOL stale = NO;
	NSURL *URL = [[NSFileManager defaultManager] fileReferenceURLFromBookmarkData:data
		stale:&stale error:error];
	if (!URL) {
		[self release];
		return nil;
	}
	int fileDescriptor = NVOpenDirectoryReferenceURL(URL, error);
	if (fileDescriptor < 0) {
		[self release];
		return nil;
	}
	self = [self initWithOwnedDirectoryFileDescriptor:fileDescriptor
		fileReferenceURL:URL bookmarkData:data error:error];
	if (self && stale) {
		NSData *fresh = [[NSFileManager defaultManager]
			bookmarkDataForFileReferenceURL:URL error:NULL];
		if (fresh) {
			[bookmarkData release];
			bookmarkData = [fresh copy];
		}
	}
	return self;
}

/* Confirms that the supplied descriptor is a directory matching the reference URL.
 * It then adopts the descriptor instead of opening the directory a second time.
 * Requires: ownership of fileDescriptor is transferred to this initializer.
 * On return: the root owns it on success, or it has been closed on failure. */
- (id)initWithOwnedDirectoryFileDescriptor:(int)fileDescriptor
	fileReferenceURL:(NSURL*)URL bookmarkData:(NSData*)data error:(NSError**)error {
	struct stat status;
	int statResult = fileDescriptor < 0 ? -1 : fstat(fileDescriptor, &status);
	int statError = errno;
	if (fileDescriptor < 0 || ![URL isFileReferenceURL] || ![data length] ||
		statResult < 0 || !S_ISDIR(status.st_mode) ||
		!NVDescriptorReferencesURL(fileDescriptor, URL)) {
		int validationError = fileDescriptor < 0 ? EBADF :
			(![URL isFileReferenceURL] || ![data length] ? EINVAL :
			(statResult < 0 ? statError : ENOTDIR));
		if (statResult == 0 && S_ISDIR(status.st_mode) &&
			[URL isFileReferenceURL] && [data length]) validationError = EAGAIN;
		if (fileDescriptor >= 0) close(fileDescriptor);
		if (error) *error = NVRootedDirectoryError(validationError, @"Open rooted directory", nil);
		[self release];
		return nil;
	}
	self = [super init];
	if (self) {
		fileReferenceURL = [URL retain];
		bookmarkData = [data copy];
		directoryFileDescriptor = fileDescriptor;
	}
	return self;
}

- (NSData*)bookmarkData { return [[bookmarkData copy] autorelease]; }
- (NSURL*)transientFileReferenceURL { return fileReferenceURL; }

static BOOL NVRootedErrorIsNoSuchFile(NSError *error) {
	return ([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == ENOENT) ||
		([[error domain] isEqualToString:NSCocoaErrorDomain] &&
		 [error code] == NSFileNoSuchFileError);
}

/* Builds the directory catalog with Foundation's URL-based enumeration.
 * The catalog lists regular filenames and the fields used to recognize later changes.
 * Requires: the live descriptor and file-reference URL identify the same directory.
 * On success: returns an owned catalog; transient moves are retried once. */
- (NVRootedDirectoryCatalog*)_newFoundationCatalog:(NSError**)error {
	#if NV_INTEGRATION_TESTING
	if ([self respondsToSelector:@selector(_didUseFoundationCatalogEnumeration)])
		[self _didUseFoundationCatalogEnumeration];
	#endif
	NSArray *keys = @[ NSURLIsRegularFileKey ];
	for (NSUInteger attempt = 0; attempt < 2; attempt++) {
		NVRootedDirectoryCatalog *catalog = [[NVRootedDirectoryCatalog alloc] init];
		NSString *directoryPath = [[self transientFileReferenceURL] path];
		if (!directoryPath) {
			[catalog release];
			if (error) *error = NVRootedDirectoryError(ENOENT,
				@"Resolve directory for compatibility enumeration", nil);
			return nil;
		}
		NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath isDirectory:YES];
		BOOL transientFailure = !NVDescriptorReferencesURL(directoryFileDescriptor, directoryURL);
		NSError *enumerationError = nil;
		NSArray *URLs = transientFailure ? nil : [[NSFileManager defaultManager]
			contentsOfDirectoryAtURL:directoryURL includingPropertiesForKeys:keys
			options:0 error:&enumerationError];
		if (!URLs) {
			[catalog release];
			if (transientFailure && !attempt) {
				[fileReferenceURL removeAllCachedResourceValues];
				continue;
			}
			if (transientFailure) {
				if (error) *error = NVRootedDirectoryError(EAGAIN,
					@"Enumerate changing directory", nil);
				return nil;
			}
			if (NVRootedErrorIsNoSuchFile(enumerationError) && !attempt) continue;
			if (error) *error = enumerationError;
			return nil;
		}
		for (NSURL *URL in URLs) {
			enumerationError = nil;
			NSDictionary *values = [URL resourceValuesForKeys:keys error:&enumerationError];
			if (!values) {
				if (NVRootedErrorIsNoSuchFile(enumerationError)) {
					transientFailure = YES;
					break;
				}
				[catalog release];
				if (error) *error = enumerationError;
				return nil;
			}
			if (![[values objectForKey:NSURLIsRegularFileKey] boolValue]) continue;
			NSString *name = [URL lastPathComponent];
			NVFileObservation *observation =
				[self observationForFileNamed:name error:&enumerationError];
			if (!observation) {
				if (NVRootedErrorIsNoSuchFile(enumerationError)) {
					transientFailure = YES;
					break;
				}
				[catalog release];
				if (error) *error = enumerationError;
				return nil;
			}
			CFMutableStringRef filename = (CFMutableStringRef)[name mutableCopy];
			const char *UTF8Name = [name UTF8String];
			if (UTF8Name && ContainsHighAscii(UTF8Name, strlen(UTF8Name)))
				CFStringNormalize(filename, kCFStringNormalizationFormC);
			if (![catalog appendOwnedFilename:filename
				attributeChangeTime:[observation attributeModificationTime]
				documentID:[observation documentID] fileID:[observation fileID]
				generationCount:[observation generationCount]]) {
				[catalog release];
				if (error) *error = NVRootedDirectoryError(ENOMEM,
					@"Build directory catalog", name);
				return nil;
			}
		}
		if (!transientFailure && !NVDescriptorReferencesURL(directoryFileDescriptor, directoryURL))
			transientFailure = YES;
		if (!transientFailure) return catalog;
		[catalog release];
		if (attempt && error) *error = NVRootedDirectoryError(EAGAIN,
			@"Enumerate changing directory", nil);
	}
	return nil;
}

/* Reads many directory entries per system call with getattrlistbulk() for speed.
 * Records are kept in compact arrays; unsupported filesystems use Foundation instead.
 * Requires: the rooted directory descriptor is open.
 * On success: returns an owned catalog from one completed scan. */
- (NVRootedDirectoryCatalog*)newCatalog:(NSError**)error {
	struct attrlist requested;
	bzero(&requested, sizeof(requested));
	requested.bitmapcount = ATTR_BIT_MAP_COUNT;
	requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
		ATTR_CMN_OBJTYPE | ATTR_CMN_CHGTIME | ATTR_CMN_GEN_COUNT |
		ATTR_CMN_DOCUMENT_ID | ATTR_CMN_FILEID;
	char buffer[64 * 1024];
	for (NSUInteger attempt = 0; attempt < 2; attempt++) {
		NVRootedDirectoryCatalog *catalog = [[NVRootedDirectoryCatalog alloc] init];
		int scanFD = openat(directoryFileDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		if (scanFD < 0) {
			int openError = errno;
			[catalog release];
			if (error) *error = NVRootedDirectoryError(openError, @"Open directory catalog", nil);
			return nil;
		}
		BOOL succeeded = YES, transientFailure = NO, useFoundation = NO;
		for (;;) {
			#if NV_INTEGRATION_TESTING
			int recordCount = [self respondsToSelector:@selector(_getattrlistbulk:attributes:buffer:size:options:)] ?
				[self _getattrlistbulk:scanFD attributes:&requested buffer:buffer
					size:sizeof(buffer) options:FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS] :
				getattrlistbulk(scanFD, &requested, buffer, sizeof(buffer),
					FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS);
			#else
			int recordCount = getattrlistbulk(scanFD, &requested, buffer, sizeof(buffer),
				FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS);
			#endif
			if (recordCount < 0) { useFoundation = YES; break; }
			if (!recordCount) break;
			const char *recordBytes = buffer;
			for (int index = 0; index < recordCount; index++) {
				size_t available = sizeof(buffer) - (size_t)(recordBytes - buffer);
				size_t recordLength = 0, nameLength = 0;
				const char *name = NULL;
				struct timespec changeTime = { 0 };
				uint32_t documentID = 0, generationCount = 0;
				uint64_t fileID = 0;
				NVBulkCatalogParseResult result = NVParseBulkCatalogRecord(recordBytes,
					available, &recordLength, &name, &nameLength, &changeTime,
					&documentID, &fileID, &generationCount);
				if (result == NVBulkCatalogRecordTransient) {
					transientFailure = YES;
					succeeded = NO;
					break;
				}
				if (result < NVBulkCatalogRecordSkipped) {
					succeeded = NO;
					break;
				}
				if (result == NVBulkCatalogRecordFile) {
					CFStringRef filename = CFStringCreateWithBytes(kCFAllocatorDefault,
						(const UInt8 *)name, nameLength, kCFStringEncodingUTF8, false);
					if (!filename) { succeeded = NO; break; }
					if (ContainsHighAscii(name, nameLength)) {
						CFMutableStringRef normalized = CFStringCreateMutableCopy(
							kCFAllocatorDefault, 0, filename);
						CFRelease(filename);
						CFStringNormalize(normalized, kCFStringNormalizationFormC);
						filename = normalized;
					}
					if (![catalog appendOwnedFilename:filename attributeChangeTime:changeTime
						documentID:documentID fileID:fileID generationCount:generationCount]) {
						succeeded = NO;
						break;
					}
				}
				recordBytes += recordLength;
			}
			if (!succeeded) break;
		}
		close(scanFD);
		if (transientFailure) {
			[catalog release];
			if (!attempt) continue;
			if (error) *error = NVRootedDirectoryError(EAGAIN,
				@"Enumerate changing directory", nil);
			return nil;
		}
		if (!succeeded || useFoundation) {
			[catalog release];
			return [self _newFoundationCatalog:error];
		}
		return catalog;
	}
	return nil;
}

/* Creates a temporary URL for a named file, then verifies it against an open descriptor.
 * The URL is only an adapter for APIs that cannot operate on descriptors. */
- (NSURL*)transientFileReferenceURLForFileNamed:(NSString*)filename error:(NSError**)error {
	NSFileHandle *handle = [self openExistingRegularFileForReadingNamed:filename error:error];
	if (!handle) return nil;
	NSURL *URL = [[NSFileManager defaultManager] fileReferenceURLForFilename:filename
		inDirectoryURL:fileReferenceURL error:error];
	if (!URL || ![self fileHandle:handle isStillNamed:filename]) {
		if (URL && error) *error = NVRootedDirectoryError(EAGAIN,
			@"Resolve changing file reference", filename);
		return nil;
	}
	return URL;
}

/* Produces the root's current text path for APIs such as FSEvents that require one.
 * It verifies that the path still names the open directory before returning it.
 * Requires: the rooted descriptor still refers to the bookmarked directory.
 * On success: stale bookmark and URL state may be replaced with fresh values. */
- (NSString*)transientPathForEventWatch:(NSError**)error {
	[fileReferenceURL removeAllCachedResourceValues];
	NSString *path = [fileReferenceURL path];
	if (path && NVDescriptorReferencesURL(directoryFileDescriptor,
		[NSURL fileURLWithPath:path isDirectory:YES])) return path;
	BOOL stale = NO;
	NSURL *resolved = [[NSFileManager defaultManager] fileReferenceURLFromBookmarkData:bookmarkData
		stale:&stale error:error];
	if (!resolved || !NVDescriptorReferencesURL(directoryFileDescriptor, resolved)) {
		if (resolved && error) *error = NVRootedDirectoryError(EAGAIN,
			@"Resolve rooted directory path", nil);
		return nil;
	}
	if (stale) {
		NSData *updated = [[NSFileManager defaultManager] bookmarkDataForFileReferenceURL:resolved error:error];
		if (!updated) return nil;
		[bookmarkData release];
		bookmarkData = [updated copy];
	}
	[fileReferenceURL release];
	fileReferenceURL = [resolved retain];
	return [fileReferenceURL path];
}

/* Uses an open descriptor to pin the intended file while Foundation moves its URL to Trash.
 * It verifies that the resulting Trash URL still identifies that same file.
 * Requires: filename remains bound to the opened regular file until the move.
 * On success: the old leaf is gone and resultingURL identifies the moved file.
 * On late verification failure: the item may already be in Trash. */
- (BOOL)moveFileToTrashUsingWorkspaceNamed:(NSString*)filename
	resultingURL:(NSURL**)resultingURL error:(NSError**)error {
	NSFileHandle *handle = [self openExistingRegularFileForReadingNamed:filename error:error];
	NSURL *URL = handle ? [self transientFileReferenceURLForFileNamed:filename error:error] : nil;
	if (!URL || ![self fileHandle:handle isStillNamed:filename]) {
		if (URL && error) *error = NVRootedDirectoryError(EAGAIN, @"Trash changing file", filename);
		return NO;
	}
	NSURL *trashedURL = nil;
	if (![[NSFileManager defaultManager] trashItemAtURL:URL resultingItemURL:&trashedURL error:error])
		return NO;
	if (!trashedURL || !NVDescriptorReferencesURL([handle fileDescriptor], trashedURL)) {
		if (error) *error = NVRootedDirectoryError(EAGAIN, @"Verify trashed file", filename);
		return NO;
	}
	if (resultingURL) *resultingURL = [trashedURL fileReferenceURL];
	return YES;
}

- (BOOL)regularFileExistsNamed:(NSString*)filename {
	char *name = NULL;
	if (!NVRootedLeafFileSystemName(filename, &name, NULL)) return NO;
	struct stat status;
	BOOL exists = fstatat(directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 &&
		S_ISREG(status.st_mode);
	free(name);
	return exists;
}

/* Opens one filename relative to the rooted directory without following symbolic links.
 * A symbolic link redirects to another path, so accepting one would escape the root.
 * Requires: filename is a valid leaf and accessMode is an open() access mode.
 * On success: the returned handle owns and will close the descriptor.
 * On failure: any descriptor opened here is closed. */
static NSFileHandle *NVOpenExistingRegularFile(int directoryFileDescriptor,
	NSString *filename, int accessMode, NSError **error) {
	char *name = NULL;
	if (!NVRootedLeafFileSystemName(filename, &name, error)) return nil;
	int fileDescriptor = openat(directoryFileDescriptor, name, accessMode | O_CLOEXEC | O_NOFOLLOW);
	int openError = errno;
	free(name);
	if (fileDescriptor < 0) {
		if (error) *error = NVRootedDirectoryError(openError, @"Open file", filename);
		return nil;
	}
	struct stat status;
	int statResult = fstat(fileDescriptor, &status);
	int statError = errno;
	if (statResult < 0 || !S_ISREG(status.st_mode)) {
		int validationError = statResult < 0 ? statError : EINVAL;
		close(fileDescriptor);
		if (error) *error = NVRootedDirectoryError(validationError, @"Open regular file", filename);
		return nil;
	}
	return [[[NSFileHandle alloc] initWithFileDescriptor:fileDescriptor closeOnDealloc:YES] autorelease];
}

- (NSFileHandle*)openExistingRegularFileForReadingNamed:(NSString*)filename error:(NSError**)error {
	return NVOpenExistingRegularFile(directoryFileDescriptor, filename, O_RDONLY, error);
}

- (NSFileHandle*)openExistingRegularFileForUpdatingNamed:(NSString*)filename error:(NSError**)error {
	return NVOpenExistingRegularFile(directoryFileDescriptor, filename, O_RDWR, error);
}

/* Creates a new file whose writes always go to the current end of the file.
 * Exclusive creation fails instead of replacing a file with the same name.
 * Requires: filename is a valid unused leaf.
 * On success: the file exists and the returned handle owns its descriptor. */
- (NSFileHandle*)createAppendOnlyFileExclusivelyNamed:(NSString*)filename
	permissions:(mode_t)permissions error:(NSError**)error {
	char *name = NULL;
	if (!NVRootedLeafFileSystemName(filename, &name, error)) return nil;
	int fileDescriptor = openat(directoryFileDescriptor, name,
		O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions);
	int openError = errno;
	free(name);
	if (fileDescriptor < 0) {
		if (error) *error = NVRootedDirectoryError(openError, @"Create append-only file", filename);
		return nil;
	}
	return [[[NSFileHandle alloc] initWithFileDescriptor:fileDescriptor closeOnDealloc:YES] autorelease];
}

- (NSFileHandle*)openExistingRegularFileNonblockingNamed:(NSString*)filename
	error:(NSError**)error {
	return NVOpenExistingRegularFile(directoryFileDescriptor, filename,
		O_RDONLY | O_NONBLOCK, error);
}

- (BOOL)fileHandle:(NSFileHandle*)handle isStillNamed:(NSString*)filename {
	char *name = NULL;
	if (!handle || !NVRootedLeafFileSystemName(filename, &name, NULL)) return NO;
	BOOL matches = NVDescriptorMatchesName([handle fileDescriptor],
		directoryFileDescriptor, name);
	free(name);
	return matches;
}

/* Reads bytes and verifies that the same unchanged file still has the requested name.
 * If it changes during the read, the method retries once rather than mixing versions. */
- (NSData*)dataFromFileNamed:(NSString*)filename error:(NSError**)error {
	for (NSUInteger attempt = 0; attempt < 2; attempt++) {
		NSFileHandle *handle = [self openExistingRegularFileForReadingNamed:filename error:error];
		if (!handle) return nil;
		NVFileSnapshot *snapshot = NVSnapshotFromInstalledDescriptor(
			[handle fileDescriptor], nil, nil, 0, error);
		if (snapshot && [self fileHandle:handle isStillNamed:filename])
			return [snapshot data];
	}
	if (error) *error = NVRootedDirectoryError(EAGAIN, @"Read changing file", filename);
	return nil;
}

- (NVFileObservation*)observationForFileNamed:(NSString*)filename error:(NSError**)error {
	NSFileHandle *handle = [self openExistingRegularFileForReadingNamed:filename error:error];
	if (!handle) return nil;
	NVFileObservation *observation = NVObservationFromFileDescriptor([handle fileDescriptor], error);
	if (!observation || ![self fileHandle:handle isStillNamed:filename]) {
		if (observation && error) *error = NVRootedDirectoryError(EAGAIN, @"Inspect changing file", filename);
		return nil;
	}
	return observation;
}

/* Returns the UUID that identifies the filesystem volume containing the root.
 * It reads through the descriptor, so no possibly stale directory path is needed. */
- (NSString*)volumeUUIDString {
	struct attrlist requested;
	bzero(&requested, sizeof(requested));
	requested.bitmapcount = ATTR_BIT_MAP_COUNT;
	requested.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID;
	struct { uint32_t length; uuid_t uuid; } attributes = { 0 };
	if (fgetattrlist(directoryFileDescriptor, &requested, &attributes, sizeof(attributes), 0) < 0)
		return nil;
	uuid_t zeroUUID = { 0 };
	if (!memcmp(attributes.uuid, zeroUUID, sizeof(zeroUUID))) return nil;
	NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:attributes.uuid];
	NSString *result = [[[uuid UUIDString] copy] autorelease];
	[uuid release];
	return result;
}

/* Looks for another filename that differs only by uppercase or lowercase letters.
 * The optional excluded name lets a file be compared without colliding with itself. */
- (BOOL)caseInsensitiveRegularFileExistsNamed:(NSString*)filename
	excludingName:(NSString*)excludedFilename {
	if (!filename) return NO;
	NVRootedDirectoryCatalog *catalog = [[self newCatalog:NULL] autorelease];
	NoteCatalogEntry *entries = [catalog entries];
	for (size_t index = 0; index < [catalog count]; index++) {
		NSString *name = (NSString*)entries[index].filename;
		if (![name isEqualToString:excludedFilename] &&
			[name caseInsensitiveCompare:filename] == NSOrderedSame) return YES;
	}
	return NO;
}

/* Renames the whole rooted directory from its current parent into another parent.
 * The open descriptor continues to identify the directory even as its path changes.
 * Requires: the root still has its original name and the destination name is unused.
 * On success: the open descriptor remains authoritative at the new location.
 * On late verification failure: the directory may already have moved. */
- (BOOL)relocateIntoDirectoryReferenceURL:(NSURL*)destinationDirectoryURL error:(NSError**)error {
	NSString *directoryName = nil;
	[fileReferenceURL getResourceValue:&directoryName forKey:NSURLNameKey error:error];
	char *name = NULL;
	if (!NVRootedLeafFileSystemName(directoryName, &name, error)) return NO;
	int oldParentFD = openat(directoryFileDescriptor, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	int validationError = oldParentFD < 0 ? errno : EAGAIN;
	int newParentFD = NVOpenDirectoryReferenceURL(destinationDirectoryURL, error);
	struct stat rootStatus = { 0 }, oldNamedStatus = { 0 };
	BOOL valid = oldParentFD >= 0 && newParentFD >= 0;
	if (valid && (fstat(directoryFileDescriptor, &rootStatus) < 0 ||
		fstatat(oldParentFD, name, &oldNamedStatus, AT_SYMLINK_NOFOLLOW) < 0)) {
		validationError = errno;
		valid = NO;
	}
	valid = valid && rootStatus.st_dev == oldNamedStatus.st_dev && rootStatus.st_ino == oldNamedStatus.st_ino;
	if (!valid) {
		if (oldParentFD >= 0) close(oldParentFD);
		if (newParentFD >= 0) close(newParentFD);
		free(name);
		if (error && !*error) *error = NVRootedDirectoryError(validationError,
			@"Validate directory relocation", directoryName);
		return NO;
	}
	int result = renameatx_np(oldParentFD, name, newParentFD, name, RENAME_EXCL);
	int moveError = errno;
	struct stat newNamedStatus = { 0 };
	if (result == 0 && (fstatat(newParentFD, name, &newNamedStatus, AT_SYMLINK_NOFOLLOW) < 0 ||
		rootStatus.st_dev != newNamedStatus.st_dev || rootStatus.st_ino != newNamedStatus.st_ino)) {
		result = -1;
		moveError = EAGAIN;
	}
	/* A cross-directory rename dirties both parents; these flushes are advisory. */
	if (result == 0) {
		(void)fsync(oldParentFD);
		(void)fsync(newParentFD);
	}
	close(oldParentFD);
	close(newParentFD);
	free(name);
	if (result < 0) {
		if (error) *error = NVRootedDirectoryError(moveError, @"Relocate directory", directoryName);
		return NO;
	}
	[fileReferenceURL removeAllCachedResourceValues];
	return YES;
}

/* Reads bytes, encoding, tags, and identity fields as one coherent snapshot.
 * "Coherent" means every value came from the same file version during the read. */
- (NVFileSnapshot*)snapshotForFileNamed:(NSString*)filename error:(NSError**)error {
	for (NSUInteger attempt = 0; attempt < 2; attempt++) {
		NSFileHandle *handle = [self openExistingRegularFileForReadingNamed:filename error:error];
		if (!handle) return nil;
		int fileDescriptor = [handle fileDescriptor];
		NVFileObservation *before = NVObservationFromFileDescriptor(fileDescriptor, error);
		NSData *fileData = before ? NVDataFromFileDescriptor(fileDescriptor, error) : nil;
		BOOL encodingPresent = NO;
		NSError *attributeError = nil;
		NSData *encodingData = fileData ? NVExtendedAttributeDataFromDescriptor(fileDescriptor,
			"com.apple.TextEncoding", self, &encodingPresent, &attributeError) : nil;
		NSStringEncoding encoding = encodingPresent ?
			NVTextEncodingFromAttributeData(encodingData, error) : 0;
		if (attributeError) {
			if (error) *error = attributeError;
			return nil;
		} else if (encodingPresent && !encoding) fileData = nil;

		NSArray *tags = nil;
		if (fileData) {
			NSURL *URL = [self transientFileReferenceURLForFileNamed:filename error:NULL];
			id cocoaValue = nil;
			BOOL cocoaAvailable = NO;
			#if NV_INTEGRATION_TESTING
			if ([self respondsToSelector:@selector(_snapshotCocoaTagsAtURL:)]) {
				cocoaValue = [self _snapshotCocoaTagsAtURL:URL];
				cocoaAvailable = cocoaValue != nil;
			} else if (URL) {
			#else
			if (URL) {
			#endif
				cocoaAvailable = [URL getResourceValue:&cocoaValue forKey:NSURLTagNamesKey error:NULL];
				if (cocoaAvailable && !cocoaValue) cocoaValue = @[];
			}
			NSArray *cocoaTags = cocoaAvailable ? NVSemanticTagNames(cocoaValue) : nil;
			if (cocoaTags) {
				#if NV_INTEGRATION_TESTING
				BOOL matches = [self respondsToSelector:
					@selector(_snapshotTagURL:referencesFileDescriptor:)] ?
					[self _snapshotTagURL:URL referencesFileDescriptor:fileDescriptor] :
					(URL && [self fileHandle:handle isStillNamed:filename]);
				#else
				BOOL matches = URL && [self fileHandle:handle isStillNamed:filename];
				#endif
				if (matches) tags = cocoaTags;
				else fileData = nil;
			} else {
				BOOL tagsPresent = NO;
				attributeError = nil;
				NSData *tagData = NVExtendedAttributeDataFromDescriptor(fileDescriptor,
					"com.apple.metadata:kMDItemOMUserTags", self, &tagsPresent, &attributeError);
				if (attributeError) {
					if (error) *error = attributeError;
					return nil;
				} else if (tagsPresent) {
					tags = tagData ? NVOpenMetaTagsFromData(tagData, error) : nil;
					if (!tags) fileData = nil;
				}
			}
		}
		NVFileObservation *after = fileData ? NVObservationFromFileDescriptor(fileDescriptor, error) : nil;
		char *name = NULL;
		struct stat namedStatus = { 0 }, descriptorStatus = { 0 };
		BOOL nameValid = NVRootedLeafFileSystemName(filename, &name, NULL);
		int namedResult = -1;
		if (after && nameValid) {
			#if NV_INTEGRATION_TESTING
			namedResult = [self _statSnapshotName:name status:&namedStatus];
			#else
			namedResult = fstatat(directoryFileDescriptor, name, &namedStatus,
				AT_SYMLINK_NOFOLLOW);
			#endif
		}
		BOOL descriptorValid = after && fstat(fileDescriptor, &descriptorStatus) == 0;
		free(name);
		if (after && [before hasSameIdentityAndRevisionAsObservation:after] &&
			[fileData length] == [after logicalSize] && descriptorValid && namedResult == 0 &&
			S_ISREG(namedStatus.st_mode) && descriptorStatus.st_dev == namedStatus.st_dev &&
			descriptorStatus.st_ino == namedStatus.st_ino)
			return [[[NVFileSnapshot alloc] initWithData:fileData tags:tags encoding:encoding
				observation:after] autorelease];
		if (attempt == 1) break;
	}
	if (error) *error = NVRootedDirectoryError(EAGAIN, @"Read changing file", filename);
	return nil;
}

/* Changes the extended attribute that records how the file's text bytes are encoded.
 * It first checks the expected snapshot so it does not reinterpret newer contents.
 * Requires: expectedSnapshot describes the currently named file.
 * On success: the attribute is synchronized and the returned snapshot is verified.
 * On failure after mutation: the encoding attribute may already have changed. */
- (NVFileSnapshot*)setTextEncoding:(NSStringEncoding)encoding
	forFileNamed:(NSString*)filename expectedSnapshot:(NVFileSnapshot*)expectedSnapshot
	error:(NSError**)error {
	if (!expectedSnapshot) {
		if (error) *error = NVRootedDirectoryError(EINVAL, @"Set text encoding", filename);
		return nil;
	}
	NSString *value = NVTextEncodingAttributeValue(encoding);
	if (!value) {
		if (error) *error = NVRootedDirectoryError(EINVAL, @"Encode text encoding", filename);
		return nil;
	}
	NSFileHandle *handle = [self openExistingRegularFileForUpdatingNamed:filename error:error];
	if (!handle) return nil;
	int fd = [handle fileDescriptor];
	NVFileObservation *before = NVObservationFromFileDescriptor(fd, error);
	if (!before || ![before hasSameIdentityAndRevisionAsObservation:[expectedSnapshot observation]]) {
		if (before && error) *error = NVRootedDirectoryError(EAGAIN, @"Reinterpret changing file", filename);
		return nil;
	}
	NSData *beforeData = NVDataFromFileDescriptor(fd, error);
	if (!beforeData || ![beforeData isEqualToData:[expectedSnapshot data]]) {
		if (beforeData && error) *error = NVRootedDirectoryError(EAGAIN, @"Reinterpret changing file", filename);
		return nil;
	}
	const char *bytes = [value UTF8String];
	if (fsetxattr(fd, "com.apple.TextEncoding", bytes, strlen(bytes), 0, 0) < 0 || fsync(fd) < 0) {
		if (error) *error = NVRootedDirectoryError(errno, @"Set text encoding", filename);
		return nil;
	}
	#if NV_INTEGRATION_TESTING
	if ([self respondsToSelector:@selector(_didSetTextEncodingForNoteNamed:fileDescriptor:)])
		[self _didSetTextEncodingForNoteNamed:filename fileDescriptor:fd];
	#endif
	NVFileSnapshot *result = NVSnapshotFromInstalledDescriptor(fd, [expectedSnapshot data],
		[expectedSnapshot tags], encoding, error);
	if (!result || ![self fileHandle:handle isStillNamed:filename]) {
		if (result && error) *error = NVRootedDirectoryError(EAGAIN, @"Reinterpret changing file", filename);
		return nil;
	}
	return result;
}

/* Sets creation and modification dates through an open descriptor, then calls fsync().
 * It checks afterward that the descriptor still has the requested filename.
 * Requires: filename remains bound to the opened regular file.
 * On success: returns an observation of the updated, still-named file.
 * On failure after mutation: one or both dates may already have changed. */
- (NVFileObservation*)setCreationTime:(CFAbsoluteTime)creationTime
	modificationTime:(CFAbsoluteTime)modificationTime forFileNamed:(NSString*)filename
	error:(NSError**)error {
	NSFileHandle *handle = [self openExistingRegularFileForUpdatingNamed:filename error:error];
	if (!handle) return nil;
	if (NVSetDescriptorDates([handle fileDescriptor],
		NVTimespecFromAbsoluteTime(creationTime),
		NVTimespecFromAbsoluteTime(modificationTime)) < 0 ||
		fsync([handle fileDescriptor]) < 0) {
		if (error) *error = NVRootedDirectoryError(errno, @"Set file dates", filename);
		return nil;
	}
	NVFileObservation *result = NVObservationFromFileDescriptor([handle fileDescriptor], error);
	if (!result || ![self fileHandle:handle isStillNamed:filename]) {
		if (result && error) *error = NVRootedDirectoryError(EAGAIN, @"Set dates on changing file", filename);
		return nil;
	}
	return result;
}

/* Runs the complete write: create a private staging file, install it, then verify it.
 * The returned disposition is the outcome category callers must handle explicitly.
 * Requires: data is non-nil and conditional replacement has an expected snapshot.
 * On return: the disposition says whether installation occurred or whether callers
 * must rescan the directory and resolve retained files. */
- (NVFileWriteResult*)_writeFileNamed:(NSString*)filename data:(NSData*)data
	intent:(NVRootedWriteIntent)intent expectedSnapshot:(NVFileSnapshot*)expectedSnapshot
	preparation:(NVRootedFilePreparationBlock)preparation
	preparedDataVerifier:(NVRootedFileVerificationBlock)verifier
	finalization:(NVRootedFileFinalizationBlock)finalization
	installedSnapshotTags:(NSArray*)installedTags encoding:(NSStringEncoding)installedEncoding {
	NSError *writeError = nil;
	if (!data || (intent == NVRootedWriteConditionalReplace && !expectedSnapshot)) {
		writeError = NVRootedDirectoryError(EINVAL, @"Store data", filename);
		return [[[NVFileWriteResult alloc] initWithDisposition:NVFileWriteNotInstalled
			capability:NVFileWriteStrongAtomicCapability installedSnapshot:nil
			error:writeError recoveryFilename:nil] autorelease];
	}
	NSString *temporaryFilename = NVTemporaryFilenameForWrite(self, filename);
	NVRootedAtomicStore store = { directoryFileDescriptor, -1, NULL, NULL, filename,
		temporaryFilename, NO, NO, NVFileWriteStrongAtomicCapability, nil };
	NSData *expectedData = intent == NVRootedWriteConditionalReplace ? [expectedSnapshot data] : nil;
	BOOL destinationExists = NO;
	BOOL installSucceeded = NO;
	if (!NVRootedLeafFileSystemName(filename, &store.destinationName, &writeError) ||
		!NVRootedLeafFileSystemName(store.temporaryFilename, &store.temporaryName, &writeError))
		goto finished;
	store.preparedFD = openat(directoryFileDescriptor, store.temporaryName,
		O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (store.preparedFD < 0) {
		writeError = NVRootedDirectoryError(errno, @"Create prepared file", store.temporaryFilename);
		goto finished;
	}
	if (!NVPrepareAtomicStore(&store, data, intent, expectedData, preparation,
		verifier, &destinationExists, &writeError)) goto finished;
	installSucceeded = destinationExists ?
		NVInstallReplacement(&store, expectedData, self, &writeError) :
		NVInstallNewFile(&store, data, preparation, self, &writeError);
	#if NV_INTEGRATION_TESTING
	if (store.namespaceInstalled && [self respondsToSelector:@selector(_didInstallNoteFileNamed:)])
		[self _didInstallNoteFileNamed:filename];
	#endif
	if (store.namespaceInstalled && store.preparedFD >= 0 && finalization &&
		!finalization(store.preparedFD, &writeError)) {
		store.reconciliationRequired = YES;
		installSucceeded = NO;
	}

finished: {
		NVFileSnapshot *installedSnapshot = nil;
		if (store.namespaceInstalled && store.preparedFD >= 0 &&
			NVDescriptorMatchesName(store.preparedFD, directoryFileDescriptor, store.destinationName)) {
			int verificationFD = openat(directoryFileDescriptor, store.destinationName,
				O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
			if (verificationFD >= 0 && NVDescriptorsReferToSameFile(store.preparedFD, verificationFD))
				installedSnapshot = NVSnapshotFromInstalledDescriptor(verificationFD, data,
					installedTags, installedEncoding, &writeError);
			if (installedSnapshot && !NVDescriptorMatchesName(verificationFD,
				directoryFileDescriptor, store.destinationName)) {
				installedSnapshot = nil;
				writeError = NVRootedDirectoryError(EAGAIN,
					@"Verify installed filename", filename);
			}
			if (verificationFD >= 0) close(verificationFD);
		}
		if (store.namespaceInstalled && !installedSnapshot) store.reconciliationRequired = YES;

		NVFileWriteDisposition disposition = NVFileWriteNotInstalled;
		if (store.namespaceInstalled) {
			if (store.reconciliationRequired || !installSucceeded)
				disposition = NVFileWriteInstalledNeedsReconciliation;
			else disposition = NVFileWriteInstalledVerified;
		}
		/* Improve crash persistence without making it part of the result contract. */
		if (store.namespaceInstalled)
			(void)fsync(directoryFileDescriptor);
		else
			(void)NVRemoveTemporaryFile(&store, store.preparedFD, self, NULL);
		if (!writeError && disposition == NVFileWriteNotInstalled)
			writeError = NVRootedDirectoryError(EIO, @"Store file", filename);
		if (!writeError && disposition == NVFileWriteInstalledNeedsReconciliation)
			writeError = NVRootedDirectoryError(EAGAIN, @"Reconcile installed file", filename);
		if (store.preparedFD >= 0) close(store.preparedFD);
		free(store.destinationName);
		free(store.temporaryName);
		return [[[NVFileWriteResult alloc] initWithDisposition:disposition
			capability:store.capability installedSnapshot:installedSnapshot
			error:writeError recoveryFilename:store.recoveryFilename] autorelease];
	}
}

- (NVFileWriteResult*)createFileNamed:(NSString*)filename withData:(NSData*)data {
	return [self _writeFileNamed:filename data:data intent:NVRootedWriteCreate
		expectedSnapshot:nil preparation:NULL preparedDataVerifier:NULL finalization:NULL
		installedSnapshotTags:nil encoding:0];
}

- (NVFileWriteResult*)replaceFileNamed:(NSString*)filename withData:(NSData*)data
	expectedSnapshot:(NVFileSnapshot*)snapshot {
	return [self _writeFileNamed:filename data:data intent:NVRootedWriteConditionalReplace
		expectedSnapshot:snapshot preparation:NULL preparedDataVerifier:NULL finalization:NULL
		installedSnapshotTags:nil encoding:0];
}

- (NVFileWriteResult*)overwriteFileNamed:(NSString*)filename withData:(NSData*)data {
	return [self _writeFileNamed:filename data:data intent:NVRootedWriteOverwrite
		expectedSnapshot:nil preparation:NULL preparedDataVerifier:NULL finalization:NULL
		installedSnapshotTags:nil encoding:0];
}

- (NVFileWriteResult*)overwriteFileNamed:(NSString*)filename withData:(NSData*)data
	preparedDataVerifier:(NVRootedFileVerificationBlock)verifier {
	return [self _writeFileNamed:filename data:data intent:NVRootedWriteOverwrite
		expectedSnapshot:nil preparation:NULL preparedDataVerifier:verifier finalization:NULL
		installedSnapshotTags:nil encoding:0];
}

NSString *NVTextEncodingAttributeValue(NSStringEncoding encoding) {
	CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding);
	if (cfEncoding == kCFStringEncodingInvalidId) return nil;
	return [(NSString*)CFStringConvertEncodingToIANACharSetName(cfEncoding)
		stringByAppendingFormat:@";%u", (unsigned int)cfEncoding];
}

/* Adds note-specific metadata before and after the common staged-write operation.
 * Extended attributes are the source of truth; Finder-visible values are only mirrors.
 * Requires: tags can be serialized and conditional replacement has a snapshot.
 * On return: disposition describes installation; verified writes have source-of-truth
 * extended attributes, often called xattrs.
 * Finder tags and extension hiding remain best effort. */
- (NVFileWriteResult*)_writeNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
	intent:(NVRootedWriteIntent)intent expectedSnapshot:(NVFileSnapshot*)expectedSnapshot {
	NSArray *authoritativeTags = tags ?: @[];
	NSArray *semanticTags = NVSemanticTagNames(authoritativeTags);
	NSError *metadataError = nil;
	NSData *tagData = semanticTags ? [NSPropertyListSerialization
		dataWithPropertyList:authoritativeTags format:NSPropertyListBinaryFormat_v1_0
		options:0 error:&metadataError] : nil;
	NSString *encodingValue = encoding ? NVTextEncodingAttributeValue(encoding) : nil;
	if (!tagData || (encoding && !encodingValue))
		return [[[NVFileWriteResult alloc] initWithDisposition:NVFileWriteNotInstalled
			capability:NVFileWriteStrongAtomicCapability installedSnapshot:nil
			error:(metadataError ?: NVRootedDirectoryError(EINVAL, @"Prepare note metadata", filename))
			recoveryFilename:nil] autorelease];
	NVRootedFilePreparationBlock preparation = ^BOOL(int fd, NSError **error) {
		if (encoding) {
			const char *bytes = [encodingValue UTF8String];
			if (fsetxattr(fd, "com.apple.TextEncoding", bytes, strlen(bytes), 0, 0) < 0) {
				if (error) *error = NVRootedDirectoryError(errno, @"Set text encoding", filename);
				return NO;
			}
		}
		if (fsetxattr(fd, "com.apple.metadata:kMDItemOMUserTags",
			[tagData bytes], [tagData length], 0, 0) < 0) {
			if (error) *error = NVRootedDirectoryError(errno, @"Set file tags", filename);
			return NO;
		}
		if (NVSetDescriptorDates(fd, NVTimespecFromAbsoluteTime(creationTime),
			NVTimespecFromAbsoluteTime(modificationTime)) < 0) {
			if (error) *error = NVRootedDirectoryError(errno, @"Set file dates", filename);
			return NO;
		}
		#if NV_INTEGRATION_TESTING
		if ([self respondsToSelector:@selector(_didPrepareNoteFileNamed:)])
			[self _didPrepareNoteFileNamed:filename];
		#endif
		return YES;
	};
	NVRootedFileFinalizationBlock finalization = ^BOOL(int fd, NSError **error) {
		NSURL *URL = [self transientFileReferenceURLForFileNamed:filename error:NULL];
		char *leafName = NULL;
		BOOL URLMatchesInstalledFile = URL && NVRootedLeafFileSystemName(filename,
			&leafName, NULL) && NVDescriptorMatchesName(fd, directoryFileDescriptor, leafName);
		free(leafName);
		if (URLMatchesInstalledFile) {
			NSError *adapterError = nil;
			#if NV_INTEGRATION_TESTING
			BOOL mirrored = [self respondsToSelector:@selector(_setCocoaTags:atURL:error:)] ?
				[self _setCocoaTags:semanticTags atURL:URL error:&adapterError] :
				[URL setResourceValue:semanticTags forKey:NSURLTagNamesKey error:&adapterError];
			#else
			BOOL mirrored = [URL setResourceValue:semanticTags
				forKey:NSURLTagNamesKey error:&adapterError];
			#endif
			if (!mirrored) NSLog(@"Could not mirror tags for '%@': %@", filename, adapterError);
			if (![URL setResourceValue:@YES forKey:NSURLHasHiddenExtensionKey error:&adapterError])
				NSLog(@"Could not hide extension for '%@': %@", filename, adapterError);
		}
		if (fsetxattr(fd, "com.apple.metadata:kMDItemOMUserTags",
			[tagData bytes], [tagData length], 0, 0) < 0 || fsync(fd) < 0) {
			if (error) *error = NVRootedDirectoryError(errno, @"Finalize file tags", filename);
			return NO;
		}
		#if NV_INTEGRATION_TESTING
		if ([self respondsToSelector:@selector(_didSynchronizeTagsForNoteNamed:fileDescriptor:)])
			[self _didSynchronizeTagsForNoteNamed:filename fileDescriptor:fd];
		#endif
		return YES;
	};
	return [self _writeFileNamed:filename data:data intent:intent
		expectedSnapshot:expectedSnapshot preparation:preparation preparedDataVerifier:NULL
		finalization:finalization installedSnapshotTags:semanticTags encoding:encoding];
}

- (NVFileWriteResult*)createNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime {
	return [self _writeNoteFileNamed:filename withData:data encoding:encoding tags:tags
		creationTime:creationTime modificationTime:modificationTime
		intent:NVRootedWriteCreate expectedSnapshot:nil];
}

- (NVFileWriteResult*)replaceNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
	expectedSnapshot:(NVFileSnapshot*)snapshot {
	return [self _writeNoteFileNamed:filename withData:data encoding:encoding tags:tags
		creationTime:creationTime modificationTime:modificationTime
		intent:NVRootedWriteConditionalReplace expectedSnapshot:snapshot];
}

- (NVFileWriteResult*)overwriteNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime {
	return [self _writeNoteFileNamed:filename withData:data encoding:encoding tags:tags
		creationTime:creationTime modificationTime:modificationTime
		intent:NVRootedWriteOverwrite expectedSnapshot:nil];
}

/* Keeps the source file open while renaming it, then verifies the new name against it.
 * A case-only rename is allowed only when both spellings identify that same file.
 * Requires: oldName is a regular file and newName is an unused valid leaf.
 * On success: the opened file is verified at newName.
 * On late verification failure: the file may already have been renamed. */
- (BOOL)renameFileNamed:(NSString*)oldName toUnusedName:(NSString*)newName error:(NSError**)error {
	NSFileHandle *sourceHandle = [self openExistingRegularFileForReadingNamed:oldName error:error];
	if (!sourceHandle) return NO;
	char *oldFSName = NULL, *newFSName = NULL;
	if (!NVRootedLeafFileSystemName(oldName, &oldFSName, error) ||
		!NVRootedLeafFileSystemName(newName, &newFSName, error)) {
		free(oldFSName); free(newFSName);
		return NO;
	}
	int result = renameatx_np(directoryFileDescriptor, oldFSName,
		directoryFileDescriptor, newFSName, RENAME_EXCL);
	int renameError = errno;
	if (result < 0 && renameError == EEXIST) {
		#if NV_INTEGRATION_TESTING
		if ([self respondsToSelector:@selector(_didObserveRenameCollisionFromName:toName:)])
			[self _didObserveRenameCollisionFromName:oldName toName:newName];
		#endif
		struct stat oldStatus, newStatus;
		if (fstatat(directoryFileDescriptor, oldFSName, &oldStatus, AT_SYMLINK_NOFOLLOW) < 0)
			renameError = errno;
		else if (fstatat(directoryFileDescriptor, newFSName, &newStatus, AT_SYMLINK_NOFOLLOW) < 0)
			renameError = errno == ENOENT ? EAGAIN : errno;
		else if (oldStatus.st_dev == newStatus.st_dev && oldStatus.st_ino == newStatus.st_ino) {
			result = renameat(directoryFileDescriptor, oldFSName, directoryFileDescriptor, newFSName);
			if (result < 0) renameError = errno;
		}
	}
	free(oldFSName); free(newFSName);
	if (result < 0) {
		if (error) *error = NVRootedDirectoryError(renameError, @"Rename file", oldName);
		return NO;
	}
	if (![self fileHandle:sourceHandle isStillNamed:newName]) {
		if (error) *error = NVRootedDirectoryError(EAGAIN, @"Verify renamed file", newName);
		return NO;
	}
	return YES;
}

- (BOOL)removeFileNamed:(NSString*)filename error:(NSError**)error {
	return [self _removeFileNamed:filename ifMatchingObservation:nil error:error];
}

- (BOOL)removeFileNamed:(NSString*)filename
	ifMatchingObservation:(NVFileObservation*)expected error:(NSError**)error {
	if (!expected) {
		if (error) *error = NVRootedDirectoryError(EINVAL, @"Remove matching file", filename);
		return NO;
	}
	return [self _removeFileNamed:filename ifMatchingObservation:expected error:error];
}

/* First renames the file to a hidden temporary name, called quarantine, then deletes it.
 * This lets the method verify the moved file and restore its original name after failure.
 * Requires: expected, when non-nil, matches the current identity and revision.
 * On success: that file is absent; on failure it may remain under its .nv-remove name. */
- (BOOL)_removeFileNamed:(NSString*)filename
	ifMatchingObservation:(NVFileObservation*)expected error:(NSError**)error {
	NSFileHandle *handle = [self openExistingRegularFileForReadingNamed:filename error:error];
	NVFileObservation *current = handle ?
		NVObservationFromFileDescriptor([handle fileDescriptor], error) : nil;
	if (!current || (expected && ![current hasSameIdentityAndRevisionAsObservation:expected]) ||
		![self fileHandle:handle isStillNamed:filename]) {
		if (current && error) *error = NVRootedDirectoryError(EAGAIN, @"Remove changing file", filename);
		return NO;
	}
	char *name = NULL, *quarantineName = NULL;
	NSString *quarantineFilename = [@".nv-remove-" stringByAppendingString:
		[[NSUUID UUID] UUIDString]];
	if (!NVRootedLeafFileSystemName(filename, &name, error) ||
		!NVRootedLeafFileSystemName(quarantineFilename, &quarantineName, error)) {
		free(name);
		free(quarantineName);
		return NO;
	}
	int result = NVRenameExclusivelyWithinDirectory(directoryFileDescriptor,
		name, quarantineName);
	int removeError = errno;
	if (result < 0) goto finished;
	NVFileObservation *movedObservation = NVObservationFromFileDescriptor(
		[handle fileDescriptor], NULL);
	BOOL movedExpectedFile = [self fileHandle:handle isStillNamed:quarantineFilename] &&
		NVObservationsHaveSameContentRevision(current, movedObservation);
	if (!movedExpectedFile) {
		if (NVRenameExclusivelyWithinDirectory(directoryFileDescriptor,
			quarantineName, name) < 0) {
			removeError = errno;
			if (error) *error = NVRootedDirectoryError(removeError,
				@"Restore changing file retained as", quarantineFilename);
		} else if (error) *error = NVRootedDirectoryError(EAGAIN,
			@"Remove changing file", filename);
		result = -1;
		goto finished;
	}
	result = unlinkat(directoryFileDescriptor, quarantineName, 0);
	removeError = errno;
	if (result < 0 && removeError == EPERM &&
		[self fileHandle:handle isStillNamed:quarantineFilename]) {
		struct stat status = { 0 };
		if (fstat([handle fileDescriptor], &status) == 0 &&
			fchflags([handle fileDescriptor], status.st_flags & ~(UF_IMMUTABLE | UF_APPEND)) == 0 &&
			[self fileHandle:handle isStillNamed:quarantineFilename]) {
			result = unlinkat(directoryFileDescriptor, quarantineName, 0);
			removeError = errno;
		}
	}
	if (result < 0) {
		int restoreResult = NVRenameExclusivelyWithinDirectory(directoryFileDescriptor,
			quarantineName, name);
		if (restoreResult < 0) {
			if (error) *error = NVRootedDirectoryError(removeError,
				@"Remove file retained as", quarantineFilename);
		} else if (error) *error = NVRootedDirectoryError(removeError,
			@"Remove file", filename);
	}

finished:
	free(name);
	free(quarantineName);
	if (result == 0) return YES;
	if (error && !*error) *error = NVRootedDirectoryError(removeError,
		@"Remove file", filename);
	return NO;
}

- (BOOL)synchronize:(NSError**)error {
	if (fsync(directoryFileDescriptor) == 0) return YES;
	if (error) *error = NVRootedDirectoryError(errno, @"Synchronize directory", nil);
	return NO;
}

- (void)dealloc {
	[fileReferenceURL release];
	[bookmarkData release];
	if (directoryFileDescriptor >= 0) close(directoryFileDescriptor);
	[super dealloc];
}

@end
