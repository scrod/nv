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
} NVFileInfo;


@interface NotationController (NotationFileManager)

long BlockSizeForNotation(NotationController *controller);
UInt32 diskUUIDIndexForNotation(NotationController *controller);

- (void)purgeOldPerDiskInfoFromNotes;
- (void)initializeDiskUUIDIfNecessary;

- (BOOL)notesDirectoryIsTrashed;

- (OSStatus)renameAndForgetNoteDatabaseFile:(NSString*)newfilename;
- (BOOL)removeSpuriousDatabaseFileNotes;

- (void)relocateNotesDirectory;

- (NSString*)uniqueFilenameForTitle:(NSString*)title fromNote:(NoteObject*)note;
- (NSURL*)fileReferenceURLForNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)createEmptyFileIfMissingNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)noteExistsWithName:(NSString*)filename;
- (NSData*)dataFromNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)renameNoteFromName:(NSString*)oldName toName:(NSString*)newName error:(NSError**)error;
- (BOOL)deleteNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)getFileInfo:(NVFileInfo*)info forNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)setCreationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
				 forNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)setTextEncoding:(NSStringEncoding)encoding forNoteNamed:(NSString*)filename error:(NSError**)error;
- (NSStringEncoding)textEncodingForNoteNamed:(NSString*)filename;
- (id)openMetaTagsForNoteNamed:(NSString*)filename;
- (BOOL)setOpenMetaTags:(id)tags forNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)setExtensionHiddenForNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)moveNoteToTrashNamed:(NSString*)filename resultingURL:(NSURL**)resultingURL error:(NSError**)error;
- (BOOL)storeDataAtomicallyInNotesDirectory:(NSData*)data
										 withName:(NSString*)filename
							 verificationBlock:(NVFileVerificationBlock)verificationBlock
											error:(NSError**)error;
@end
