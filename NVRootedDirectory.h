//
//  NVRootedDirectory.h
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

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSUInteger, NVFileWriteDisposition) {
	/* The requested destination was not installed; error is non-nil. */
	NVFileWriteNotInstalled = 0,
	/* The retained descriptor still owns the name and exact contents were read back. */
	NVFileWriteInstalledVerified,
	/* Installed, but the caller must rescan; recoveryFilename may identify preserved bytes. */
	NVFileWriteInstalledNeedsReconciliation
};

typedef NS_ENUM(NSUInteger, NVFileWriteCapability) {
	NVFileWriteStrongAtomicCapability = 0,
	NVFileWriteHFSCompatibilityCapability,
	NVFileWriteBestEffortCapability
};

NSComparisonResult NVCompareTimespecs(struct timespec one, struct timespec two);
CFAbsoluteTime NVAbsoluteTimeFromTimespec(struct timespec value);
struct timespec NVTimespecFromAbsoluteTime(CFAbsoluteTime time);

@interface NVFileObservation : NSObject <NSCopying> {
	struct timespec creationTime;
	struct timespec modificationTime;
	struct timespec attributeModificationTime;
	uint64_t logicalSize;
	uint64_t fileID;
	uint32_t documentID;
	uint32_t generationCount;
}

@property(nonatomic, readonly) struct timespec creationTime;
@property(nonatomic, readonly) struct timespec modificationTime;
@property(nonatomic, readonly) struct timespec attributeModificationTime;
@property(nonatomic, readonly) uint64_t logicalSize;
@property(nonatomic, readonly) uint64_t fileID;
@property(nonatomic, readonly) uint32_t documentID;
@property(nonatomic, readonly) uint32_t generationCount;

- (id)initWithCreationTime:(struct timespec)creation
	modificationTime:(struct timespec)modification
	attributeModificationTime:(struct timespec)attributeModification
	logicalSize:(uint64_t)size fileID:(uint64_t)identifier
	documentID:(uint32_t)documentIdentifier generationCount:(uint32_t)generation;
- (BOOL)hasSameIdentityAndRevisionAsObservation:(NVFileObservation*)observation;

@end

@interface NVFileSnapshot : NSObject {
	NSData *data;
	NSArray *tags;
	NSStringEncoding encoding;
	NVFileObservation *observation;
}

@property(nonatomic, readonly, retain) NSData *data;
/* nil means unavailable; an empty array is an authoritative empty tag set. */
@property(nonatomic, readonly, retain) NSArray *tags;
@property(nonatomic, readonly) NSStringEncoding encoding;
@property(nonatomic, readonly, retain) NVFileObservation *observation;

- (id)initWithData:(NSData*)fileData tags:(NSArray*)fileTags
	encoding:(NSStringEncoding)textEncoding observation:(NVFileObservation*)fileObservation;

@end


@interface NVFileWriteResult : NSObject {
	NVFileWriteDisposition disposition;
	NVFileWriteCapability capability;
	NVFileSnapshot *installedSnapshot;
	NSError *error;
	NSString *recoveryFilename;
}

@property(nonatomic, readonly) NVFileWriteDisposition disposition;
@property(nonatomic, readonly) NVFileWriteCapability capability;
@property(nonatomic, readonly, retain) NVFileSnapshot *installedSnapshot;
@property(nonatomic, readonly, retain) NSError *error;
@property(nonatomic, readonly, copy) NSString *recoveryFilename;

@end


@interface NVRootedDirectory : NSObject

- (id)initWithFileReferenceURL:(NSURL*)URL error:(NSError**)error;
- (id)initWithBookmarkData:(NSData*)data error:(NSError**)error;

@property(nonatomic, readonly, copy) NSData *bookmarkData;

- (NSURL*)transientFileReferenceURL;
- (NSURL*)transientFileReferenceURLForFileNamed:(NSString*)filename error:(NSError**)error;
- (NSString*)transientPathForEventWatch:(NSError**)error;
- (BOOL)moveFileToTrashUsingWorkspaceNamed:(NSString*)filename
	resultingURL:(NSURL**)resultingURL error:(NSError**)error;

- (BOOL)regularFileExistsNamed:(NSString*)filename;
- (NSFileHandle*)createAppendOnlyFileExclusivelyNamed:(NSString*)filename
	permissions:(mode_t)permissions error:(NSError**)error;
- (NSFileHandle*)openExistingRegularFileNonblockingNamed:(NSString*)filename
	error:(NSError**)error;
- (BOOL)fileHandle:(NSFileHandle*)handle isStillNamed:(NSString*)filename;
- (NSData*)dataFromFileNamed:(NSString*)filename error:(NSError**)error;
- (NVFileObservation*)observationForFileNamed:(NSString*)filename error:(NSError**)error;
- (NVFileSnapshot*)snapshotForFileNamed:(NSString*)filename error:(NSError**)error;
- (NSString*)volumeUUIDString;
- (BOOL)caseInsensitiveRegularFileExistsNamed:(NSString*)filename
	excludingName:(NSString*)excludedFilename;
- (BOOL)relocateIntoDirectoryReferenceURL:(NSURL*)destinationDirectoryURL error:(NSError**)error;
- (NVFileSnapshot*)setTextEncoding:(NSStringEncoding)encoding
	forFileNamed:(NSString*)filename expectedSnapshot:(NVFileSnapshot*)snapshot error:(NSError**)error;
- (NVFileObservation*)setCreationTime:(CFAbsoluteTime)creationTime
	modificationTime:(CFAbsoluteTime)modificationTime forFileNamed:(NSString*)filename
	error:(NSError**)error;

/* These three operations deliberately encode write semantics without flags or sentinel nils. */
- (NVFileWriteResult*)createFileNamed:(NSString*)filename withData:(NSData*)data;
- (NVFileWriteResult*)replaceFileNamed:(NSString*)filename withData:(NSData*)data
	expectedSnapshot:(NVFileSnapshot*)snapshot;
- (NVFileWriteResult*)overwriteFileNamed:(NSString*)filename withData:(NSData*)data;

- (NVFileWriteResult*)createNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime;
- (NVFileWriteResult*)replaceNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
	expectedSnapshot:(NVFileSnapshot*)snapshot;
- (NVFileWriteResult*)overwriteNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime;

- (BOOL)renameFileNamed:(NSString*)oldName toUnusedName:(NSString*)newName error:(NSError**)error;
- (BOOL)removeFileNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)removeFileNamed:(NSString*)filename
	ifMatchingObservation:(NVFileObservation*)observation error:(NSError**)error;
/* Ordinary filesystem synchronization at an explicit caller-owned transaction boundary;
 * success is not a hardware power-loss guarantee. */
- (BOOL)synchronize:(NSError**)error;

@end
