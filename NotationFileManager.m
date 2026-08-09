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
#import <CommonCrypto/CommonCrypto.h>
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/attr.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

NSString *NotesDatabaseFileName = @"Notes & Settings";

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

static struct statfs *StatFSVolumeInfo(NotationController *controller);

- (NSURL*)fileReferenceURLForNoteNamed:(NSString*)filename error:(NSError**)error {
	return [[NSFileManager defaultManager] fileReferenceURLForFilename:filename
		inDirectoryURL:noteDirectoryURL error:error];
}

- (BOOL)createEmptyFileIfMissingNamed:(NSString*)filename error:(NSError**)error {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return NO;
	int fd = openat(noteDirectoryFileDescriptor, name,
		O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	int openError = errno;
	free(name);
	if (fd >= 0) {
		close(fd);
		return YES;
	}
	if (openError == EEXIST) return [self noteExistsWithName:filename];
	if (error) *error = NVErrorFromErrno(openError, @"Create file", filename);
	return NO;
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
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return nil;
	int fileDescriptor = openat(noteDirectoryFileDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
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

- (BOOL)renameNoteFromName:(NSString*)oldName toName:(NSString*)newName error:(NSError**)error {
	char *oldFSName = NULL;
	char *newFSName = NULL;
	if (!NVFileSystemName(oldName, &oldFSName, error) ||
		!NVFileSystemName(newName, &newFSName, error)) {
		free(oldFSName);
		free(newFSName);
		return NO;
	}
	int result = renameatx_np(noteDirectoryFileDescriptor, oldFSName,
		noteDirectoryFileDescriptor, newFSName, RENAME_EXCL);
	int renameError = errno;
	if (result < 0 && renameError == EEXIST) {
		struct stat oldInfo;
		struct stat newInfo;
		if (fstatat(noteDirectoryFileDescriptor, oldFSName, &oldInfo, AT_SYMLINK_NOFOLLOW) == 0 &&
			fstatat(noteDirectoryFileDescriptor, newFSName, &newInfo, AT_SYMLINK_NOFOLLOW) == 0 &&
			oldInfo.st_dev == newInfo.st_dev && oldInfo.st_ino == newInfo.st_ino)
			result = renameat(noteDirectoryFileDescriptor, oldFSName, noteDirectoryFileDescriptor, newFSName);
	} else if (result < 0 && (renameError == ENOTSUP || renameError == EINVAL)) {
		result = linkat(noteDirectoryFileDescriptor, oldFSName,
			noteDirectoryFileDescriptor, newFSName, 0);
		if (result == 0 && unlinkat(noteDirectoryFileDescriptor, oldFSName, 0) < 0) {
			renameError = errno;
			(void)unlinkat(noteDirectoryFileDescriptor, newFSName, 0);
			result = -1;
		}
	}
	if (result < 0) renameError = errno;
	free(oldFSName);
	free(newFSName);
	if (result < 0) {
		if (error) *error = NVErrorFromErrno(renameError, @"Rename file", oldName);
		return NO;
	}
	return YES;
}

- (BOOL)deleteNoteNamed:(NSString*)filename error:(NSError**)error {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return NO;
	int result = unlinkat(noteDirectoryFileDescriptor, name, 0);
	int unlinkError = errno;
	free(name);
	if (result < 0) {
		if (error) *error = NVErrorFromErrno(unlinkError, @"Delete file", filename);
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
	struct stat status;
	int result = fstatat(noteDirectoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW);
	int statusError = errno;
	free(name);
	if (result < 0 || !S_ISREG(status.st_mode)) {
		if (error) *error = NVErrorFromErrno(result < 0 ? statusError : EINVAL, @"Inspect file", filename);
		return NO;
	}
	info->creationTime = status.st_birthtimespec;
	info->modificationTime = status.st_mtimespec;
	info->attributeModificationTime = status.st_ctimespec;
	info->logicalSize = (uint64_t)status.st_size;
	info->fileID = (uint64_t)status.st_ino;
	return YES;
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

- (BOOL)setTextEncoding:(NSStringEncoding)encoding forNoteNamed:(NSString*)filename error:(NSError**)error {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return NO;
	int fd = openat(noteDirectoryFileDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	int openError = errno;
	free(name);
	if (fd < 0) {
		if (error) *error = NVErrorFromErrno(openError, @"Open file", filename);
		return NO;
	}
	NSString *value = NVTextEncodingAttributeValue(encoding);
	const char *bytes = [value UTF8String];
	int result = value ? fsetxattr(fd, "com.apple.TextEncoding", bytes, strlen(bytes), 0, 0) : -1;
	int xattrError = value ? errno : EINVAL;
	close(fd);
	if (result < 0) {
		if (error) *error = NVErrorFromErrno(xattrError, @"Set text encoding", filename);
		return NO;
	}
	return YES;
}

- (NSStringEncoding)textEncodingForNoteNamed:(NSString*)filename {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, NULL)) return 0;
	int fd = openat(noteDirectoryFileDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	free(name);
	if (fd < 0) return 0;
	char value[128] = {0};
	ssize_t length = fgetxattr(fd, "com.apple.TextEncoding", value, sizeof(value) - 1, 0, 0);
	close(fd);
	if (length <= 0) return 0;
	NSString *string = [NSString stringWithUTF8String:value];
	NSArray *parts = [string componentsSeparatedByString:@";"];
	if ([parts count] > 1)
		return CFStringConvertEncodingToNSStringEncoding([[parts objectAtIndex:1] intValue]);
	return CFStringConvertEncodingToNSStringEncoding(
		CFStringConvertIANACharSetNameToEncoding((CFStringRef)[parts objectAtIndex:0]));
}

- (id)openMetaTagsForNoteNamed:(NSString*)filename {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, NULL)) return nil;
	int fd = openat(noteDirectoryFileDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	free(name);
	if (fd < 0) return nil;
	ssize_t size = fgetxattr(fd, "com.apple.metadata:kMDItemOMUserTags", NULL, 0, 0, 0);
	if (size <= 0) { close(fd); return nil; }
	NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
	size = fgetxattr(fd, "com.apple.metadata:kMDItemOMUserTags", [data mutableBytes], [data length], 0, 0);
	close(fd);
	if (size <= 0) return nil;
	return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
}

- (BOOL)setOpenMetaTags:(id)tags forNoteNamed:(NSString*)filename error:(NSError**)error {
	char *name = NULL;
	if (!NVFileSystemName(filename, &name, error)) return NO;
	int fd = openat(noteDirectoryFileDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	int openError = errno;
	free(name);
	if (fd < 0) {
		if (error) *error = NVErrorFromErrno(openError, @"Open file", filename);
		return NO;
	}
	NSData *data = tags ? [NSPropertyListSerialization dataWithPropertyList:tags
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:error] : nil;
	int result = data ? fsetxattr(fd, "com.apple.metadata:kMDItemOMUserTags", [data bytes], [data length], 0, 0) :
		fremovexattr(fd, "com.apple.metadata:kMDItemOMUserTags", 0);
	int xattrError = errno;
	close(fd);
	if (result < 0 && !(data == nil && xattrError == ENOATTR)) {
		if (error && !*error) *error = NVErrorFromErrno(xattrError, @"Set file tags", filename);
		return NO;
	}
	return YES;
}

- (BOOL)setExtensionHiddenForNoteNamed:(NSString*)filename error:(NSError**)error {
	NSURL *url = [self fileReferenceURLForNoteNamed:filename error:error];
	return url && [url setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLHasHiddenExtensionKey error:error];
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
	if (!data) {
		if (error) *error = NVErrorFromErrno(EINVAL, @"Store data", filename);
		return NO;
	}
	char *destinationName = NULL;
	if (!NVFileSystemName(filename, &destinationName, error)) return NO;

	NSString *temporaryFilename = [@".nv-write-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	char *temporaryName = NULL;
	if (!NVFileSystemName(temporaryFilename, &temporaryName, error)) {
		free(destinationName);
		return NO;
	}
	int temporaryFD = openat(noteDirectoryFileDescriptor, temporaryName,
		O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (temporaryFD < 0) {
		if (error) *error = NVErrorFromErrno(errno, @"Create temporary file", temporaryFilename);
		free(destinationName);
		free(temporaryName);
		return NO;
	}

	BOOL installed = NO;
	BOOL success = NVWriteDataToFileDescriptor(data, temporaryFD, error);
	if (success && fsync(temporaryFD) < 0) {
		if (error) *error = NVErrorFromErrno(errno, @"Synchronize temporary file", temporaryFilename);
		success = NO;
	}
	if (success && verificationBlock) {
		NSData *readBack = NVReadDataFromFileDescriptor(temporaryFD, error);
		success = readBack && verificationBlock(readBack, error);
	}

	int destinationFD = -1;
	BOOL destinationExists = NO;
	if (success) {
		destinationFD = openat(noteDirectoryFileDescriptor, destinationName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
		destinationExists = destinationFD >= 0;
		if (!destinationExists && errno != ENOENT) {
			if (error) *error = NVErrorFromErrno(errno, @"Open destination", filename);
			success = NO;
		}
	}
	if (success && destinationExists) {
		struct stat temporaryInfo;
		struct timespec times[2];
		int statResult = fstat(temporaryFD, &temporaryInfo);
		if (statResult == 0) {
			times[0] = temporaryInfo.st_atimespec;
			times[1] = temporaryInfo.st_mtimespec;
		}
		if (statResult < 0 ||
			fcopyfile(destinationFD, temporaryFD, NULL, COPYFILE_METADATA) < 0 ||
			futimens(temporaryFD, times) < 0 || fsync(temporaryFD) < 0) {
			if (error) *error = NVErrorFromErrno(errno, @"Preserve destination metadata", filename);
			success = NO;
		}
	}
	if (destinationFD >= 0) close(destinationFD);

	if (success && destinationExists) {
		if (renameatx_np(noteDirectoryFileDescriptor, temporaryName,
			noteDirectoryFileDescriptor, destinationName, RENAME_SWAP) == 0) {
			installed = YES;
			if (unlinkat(noteDirectoryFileDescriptor, temporaryName, 0) < 0)
				NSLog(@"Unable to remove replaced file '%@': %s", temporaryFilename, strerror(errno));
		} else if ((errno == ENOTSUP || errno == EINVAL) &&
			renameat(noteDirectoryFileDescriptor, temporaryName,
				noteDirectoryFileDescriptor, destinationName) == 0) {
			installed = YES;
		} else if (error) {
			*error = NVErrorFromErrno(errno, @"Install replacement", filename);
		}
	} else if (success) {
		if (renameatx_np(noteDirectoryFileDescriptor, temporaryName,
			noteDirectoryFileDescriptor, destinationName, RENAME_EXCL) == 0)
			installed = YES;
		else if ((errno == ENOTSUP || errno == EINVAL) &&
			linkat(noteDirectoryFileDescriptor, temporaryName,
				noteDirectoryFileDescriptor, destinationName, 0) == 0) {
			installed = YES;
			(void)unlinkat(noteDirectoryFileDescriptor, temporaryName, 0);
		}
		else if (error)
			*error = NVErrorFromErrno(errno, @"Install new file", filename);
	}

	if (!installed) (void)unlinkat(noteDirectoryFileDescriptor, temporaryName, 0);
	if (installed) (void)fsync(noteDirectoryFileDescriptor);
	close(temporaryFD);
	free(destinationName);
	free(temporaryName);
	return installed;
}

// Create a version 3 UUID; derived using "name" via MD5 checksum.
static void uuid_create_md5_from_name(unsigned char result_uuid[16], const void *name, int namelen) {
	
	static unsigned char FSUUIDNamespaceSHA1[16] = { 
		0xB3, 0xE2, 0x0F, 0x39, 0xF2, 0x92, 0x11, 0xD6, 
		0x97, 0xA4, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC
	};
	
	CC_MD5_CTX c;

	CC_MD5_Init(&c);
	CC_MD5_Update(&c, FSUUIDNamespaceSHA1, (CC_LONG)sizeof(FSUUIDNamespaceSHA1));
	CC_MD5_Update(&c, name, (CC_LONG)namelen);
	CC_MD5_Final(result_uuid, &c);

    result_uuid[6] = (result_uuid[6] & 0x0F) | 0x30;
    result_uuid[8] = (result_uuid[8] & 0x3F) | 0x80;
}


- (void)purgeOldPerDiskInfoFromNotes {
	//here's where notes' PerDiskInfo arrays would have older times removed, depending on -[DiskUUIDEntry lastAccessed]
	//each note will use RemovePerDiskInfoWithTableIndex
}

- (void)initializeDiskUUIDIfNecessary {
	//create a CFUUIDRef that identifies the volume this database sits on
	
	//don't bother unless we will be reading notes as separate files; otherwise there's no need to track the source of the attr mod dates
	//maybe disk UUIDs will be used in the future for something else; at that point this check should be altered
	
	if (!diskUUID && [self currentNoteStorageFormat] != SingleDatabaseFormat) {
		
		struct statfs * sfsb = StatFSVolumeInfo(self);
		struct attrlist attributes;
		bzero(&attributes, sizeof(attributes));
		attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
		attributes.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID;
		struct {
			uint32_t length;
			uuid_t uuid;
		} volumeAttributes;
		if (fgetattrlist(noteDirectoryFileDescriptor, &attributes, &volumeAttributes,
			sizeof(volumeAttributes), 0) == 0) {
			CFUUIDBytes bytes;
			memcpy(&bytes, volumeAttributes.uuid, sizeof(bytes));
			diskUUID = CFUUIDCreateFromUUIDBytes(NULL, bytes);
		}
			if (!diskUUID && sfsb)
				diskUUID = FSEventsCopyUUIDForDevice(sfsb->f_fsid.val[0]);
			if (!diskUUID) {
				CFUUIDBytes bytes;
				struct stat directoryInfo;
				if (fstat(noteDirectoryFileDescriptor, &directoryInfo) < 0) return;
				uuid_create_md5_from_name((void*)&bytes, &directoryInfo.st_dev, sizeof(directoryInfo.st_dev));
				diskUUID = CFUUIDCreateFromUUIDBytes(NULL, bytes);
		}
			diskUUIDIndex = (unsigned int)[notationPrefs tableIndexOfDiskUUID:diskUUID];
	}
}

static struct statfs *StatFSVolumeInfo(NotationController *controller) {
	if (!controller->statfsInfo) {
		controller->statfsInfo = calloc(1, sizeof(struct statfs));
		if (fstatfs(controller->noteDirectoryFileDescriptor, controller->statfsInfo)) {
			NSLog(@"fstatfs: error %d\n", errno);
			free(controller->statfsInfo);
			controller->statfsInfo = NULL;
		}
	}
	return controller->statfsInfo;
}

UInt32 diskUUIDIndexForNotation(NotationController *controller) {
	return controller->diskUUIDIndex;
}

long BlockSizeForNotation(NotationController *controller) {
    if (!controller->blockSize) {
		long iosize = 0;

		struct statfs * sfsb = StatFSVolumeInfo(controller);
		if (sfsb) iosize = sfsb->f_iosize;
		
		controller->blockSize = MAX(iosize, 16 * 1024);
    }
    
    return controller->blockSize;
}

- (BOOL)notesDirectoryIsTrashed {
	NSURL *trashURL = [[NSFileManager defaultManager] URLForDirectory:NSTrashDirectory
		inDomain:NSUserDomainMask appropriateForURL:noteDirectoryURL create:NO error:NULL];
	NSURL *trashReferenceURL = [[NSFileManager defaultManager] fileReferenceURLForURL:trashURL error:NULL];
	int trashFD = trashReferenceURL ? [[NSFileManager defaultManager]
		openFileDescriptorForDirectoryReferenceURL:trashReferenceURL error:NULL] : -1;
	int currentFD = openat(noteDirectoryFileDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	struct stat trashInfo;
	BOOL found = NO;
	if (trashFD >= 0 && currentFD >= 0 && fstat(trashFD, &trashInfo) == 0) {
		for (;;) {
			struct stat currentInfo, parentInfo;
			if (fstat(currentFD, &currentInfo) < 0) break;
			if (currentInfo.st_dev == trashInfo.st_dev && currentInfo.st_ino == trashInfo.st_ino) {
				found = YES;
				break;
			}
			int parentFD = openat(currentFD, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
			if (parentFD < 0 || fstat(parentFD, &parentInfo) < 0) {
				if (parentFD >= 0) close(parentFD);
				break;
			}
			if (currentInfo.st_dev == parentInfo.st_dev && currentInfo.st_ino == parentInfo.st_ino) {
				close(parentFD);
				break;
			}
			close(currentFD);
			currentFD = parentFD;
		}
	}
	if (currentFD >= 0) close(currentFD);
	if (trashFD >= 0) close(trashFD);
	return found;
}

- (OSStatus)renameAndForgetNoteDatabaseFile:(NSString*)newfilename {
	//this method does not move the note database file; for now it is used in cases of upgrading incompatible files
	NSError *error = nil;
	if (![self renameNoteFromName:NotesDatabaseFileName toName:newfilename error:&error]) {
		NSLog(@"Error renaming notes database file to %@: %@", newfilename, error);
		return ioErr;
	}
	return noErr;
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
				[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:[NSArray arrayWithObject:noteDirectoryURL]];
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
	
	//remove illegal characters
	NSMutableString *sanitizedName = [[[uniqueFilename stringByReplacingOccurrencesOfString:@":" withString:@"-"] mutableCopy] autorelease];
	if ([sanitizedName characterAtIndex:0] == (unichar)'.')	[sanitizedName replaceCharactersInRange:NSMakeRange(0, 1) withString:@"_"];
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
		unsigned int i;
		
		//this ought to just use an nsset, but then we'd have to maintain a parallel data structure for marginal benefit
		//also, it won't quite work right for filenames with no (real) extensions and periods in their names
		for (i=0; i<[allNotes count]; i++) {
			NoteObject *aNote = [allNotes objectAtIndex:i];
			NSString *basefilename = [filenameOfNote(aNote) stringByDeletingPathExtension];
			
			if (note != aNote && [basefilename caseInsensitiveCompare:uniqueFilename] == NSOrderedSame) {
				isUnique = NO;
				
				uniqueFilename = [uniqueFilename stringByDeletingPathExtension];
				NSString *numberPath = [[NSNumber numberWithInt:++iteration] stringValue];
				uniqueFilename = [uniqueFilename stringByAppendingPathExtension:numberPath];
				break;
			}
		}
    } while (!isUnique);
	
    return [uniqueFilename stringByAppendingPathExtension:extension];
}

@end
