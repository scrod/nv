//
//  NotationFileManager.h
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


#import <Cocoa/Cocoa.h>
#import "NotationController.h"

extern NSString *NotesDatabaseFileName;

typedef BOOL (^NVFileVerificationBlock)(NSData *readBackData, NSError **error);

typedef struct _NVFileInfo {
	struct timespec creationTime;
	struct timespec modificationTime;
	struct timespec attributeModificationTime;
	uint64_t logicalSize;
	uint64_t fileID;
	uint32_t documentID;
	uint32_t generationCount;
} NVFileInfo;

/*
 * A coherent view of one note file.  Object fields follow normal autoreleased
 * return-value ownership and are valid for the caller's current autorelease
 * scope; the struct itself owns nothing and needs no cleanup.  A nil tags value
 * means the xattr is absent, while an empty array means it is present and empty.
 */
typedef struct _NVNoteFileSnapshot {
	NSData *data;
	NSArray *tags;
	NSStringEncoding encoding;
	NVFileInfo info;
} NVNoteFileSnapshot;

BOOL NVReplaceDataAtomicallyAtDirectoryFileDescriptor(int directoryFileDescriptor,
	NSData *data, NSString *filename, NSData *expectedData, NSError **error);


@interface NotationController (NotationFileManager)

- (void)initializeFileMetadataVolumeUUID;
- (BOOL)archivedFileMetadataIsForCurrentVolume;

- (BOOL)notesDirectoryIsTrashed;

- (BOOL)renameAndForgetNoteDatabaseFile:(NSString*)newfilename error:(NSError**)error;
- (BOOL)removeSpuriousDatabaseFileNotes;

- (void)relocateNotesDirectory;

- (NSString*)uniqueFilenameForTitle:(NSString*)title fromNote:(NoteObject*)note;
- (NSURL*)fileReferenceURLForNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)noteExistsWithName:(NSString*)filename;
- (NSData*)dataFromNoteNamed:(NSString*)filename error:(NSError**)error;
- (NSData*)dataFromNoteNamed:(NSString*)filename creatingIfMissing:(BOOL)create error:(NSError**)error;
- (BOOL)readNoteFileSnapshot:(NVNoteFileSnapshot*)snapshot
				forNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)renameNoteFromName:(NSString*)oldName toName:(NSString*)newName error:(NSError**)error;
- (BOOL)getFileInfo:(NVFileInfo*)info forNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)setCreationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
				 forNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)setTextEncoding:(NSStringEncoding)encoding forNoteNamed:(NSString*)filename
	matchingFileInfo:(const NVFileInfo*)expectedInfo expectedData:(NSData*)expectedData
	resultingFileInfo:(NVFileInfo*)resultingInfo error:(NSError**)error;
- (BOOL)moveNoteToTrashNamed:(NSString*)filename resultingURL:(NSURL**)resultingURL error:(NSError**)error;
- (BOOL)storeDataAtomicallyInNotesDirectory:(NSData*)data
										 withName:(NSString*)filename
							 verificationBlock:(NVFileVerificationBlock)verificationBlock
											error:(NSError**)error;
- (BOOL)storeNoteDataAtomically:(NSData*)data withName:(NSString*)filename
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
	expectedData:(NSData*)expectedData
	resultingFileInfo:(NVFileInfo*)resultingFileInfo error:(NSError**)error;
@end
