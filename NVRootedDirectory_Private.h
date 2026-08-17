//
//  NVRootedDirectory_Private.h
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

// Internal capability surface. Never include this header from UI or model code.

#import "NVRootedDirectory.h"
#include <sys/stat.h>

typedef BOOL (^NVRootedFileVerificationBlock)(NSData *readBackData, NSError **error);
int NVBarrierSyncFileDescriptor(int fileDescriptor);
NSArray *NVSemanticTagNames(NSArray *tags);
NSString *NVTextEncodingAttributeValue(NSStringEncoding encoding);

typedef struct _NoteCatalogEntry {
	struct timespec attributeChangeTime;
	uint64_t fileID;
	CFStringRef filename;
	uint32_t documentID;
	uint32_t generationCount;
} NoteCatalogEntry;

typedef NS_ENUM(NSInteger, NVBulkCatalogParseResult) {
	NVBulkCatalogRecordMalformed = -3,
	NVBulkCatalogRecordUnsupported = -2,
	NVBulkCatalogRecordTransient = -1,
	NVBulkCatalogRecordSkipped = 0,
	NVBulkCatalogRecordFile = 1
};

NVBulkCatalogParseResult NVParseBulkCatalogRecord(const void *bytes, size_t availableLength,
	size_t *recordLength, const char **name, size_t *nameLength, struct timespec *changeTime,
	uint32_t *documentID, uint64_t *fileID, uint32_t *generationCount);

@interface NVRootedDirectoryCatalog : NSObject {
	NoteCatalogEntry *entries;
	NoteCatalogEntry **sortedEntries;
	size_t count, capacity;
}
- (NoteCatalogEntry*)entries;
- (NoteCatalogEntry**)sortedEntries;
- (size_t)count;
- (BOOL)appendOwnedFilename:(CFStringRef CF_CONSUMED)filename
	attributeChangeTime:(struct timespec)changeTime documentID:(uint32_t)documentID
	fileID:(uint64_t)fileID generationCount:(uint32_t)generationCount;
- (void)sortCaseInsensitively;
- (BOOL)isExactlyEqualToCatalog:(NVRootedDirectoryCatalog*)catalog;
@end

@interface NVRootedDirectory (Private)

- (id)initWithOwnedDirectoryFileDescriptor:(int)fileDescriptor
	fileReferenceURL:(NSURL*)URL bookmarkData:(NSData*)data error:(NSError**)error;
- (NSFileHandle*)openExistingRegularFileForReadingNamed:(NSString*)filename error:(NSError**)error;
- (NSFileHandle*)openExistingRegularFileForUpdatingNamed:(NSString*)filename error:(NSError**)error;
- (NVRootedDirectoryCatalog*)newCatalog:(NSError**)error;
- (NVFileWriteResult*)overwriteFileNamed:(NSString*)filename withData:(NSData*)data
	preparedDataVerifier:(NVRootedFileVerificationBlock)verifier;

@end

@interface NVFileWriteResult (Private)
- (id)initWithDisposition:(NVFileWriteDisposition)aDisposition
	capability:(NVFileWriteCapability)aCapability installedSnapshot:(NVFileSnapshot*)snapshot
	error:(NSError*)writeError recoveryFilename:(NSString*)filename;
@end
