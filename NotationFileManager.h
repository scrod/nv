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
#include "FSExchangeObjectsCompat.h"
#import "BufferUtils.h"

extern NSString *NotesDatabaseFileName;

typedef union VolumeUUID {
	u_int32_t value[2];
	struct {
		u_int32_t high;
		u_int32_t low;
	} v;
} VolumeUUID;


@interface NotationController (NotationFileManager)

OSStatus CreateTemporaryFile(FSRef *parentRef, FSRef *childTempRef);
OSStatus CreateDirectoryIfNotPresent(FSRef *parentRef, CFStringRef subDirectoryName, FSRef *childRef);
CFUUIDRef CopyHFSVolumeUUIDForMount(const char *mntonname);
long BlockSizeForNotation(NotationController *controller);
UInt32 diskUUIDIndexForNotation(NotationController *controller);

- (void)purgeOldPerDiskInfoFromNotes;
- (void)initializeDiskUUIDIfNecessary;

- (BOOL)notesDirectoryIsTrashed;

- (BOOL)notesDirectoryContainsFile:(NSString*)filename returningFSRef:(FSRef*)childRef;
- (OSStatus)refreshFileRefIfNecessary:(FSRef *)childRef withName:(NSString *)filename charsBuffer:(UniChar*)charsBuffer;

- (OSStatus)renameAndForgetNoteDatabaseFile:(NSString*)newfilename;
- (BOOL)removeSpuriousDatabaseFileNotes;

- (void)relocateNotesDirectory;

+ (OSStatus)getDefaultNotesDirectoryRef:(FSRef*)notesDir;

- (NSMutableData*)dataFromFileInNotesDirectory:(FSRef*)childRef forFilename:(NSString*)filename;
- (NSMutableData*)dataFromFileInNotesDirectory:(FSRef*)childRef forCatalogEntry:(NoteCatalogEntry*)catEntry;
- (NSMutableData*)dataFromFileInNotesDirectory:(FSRef*)childRef forFilename:(NSString*)filename fileSize:(UInt64)givenFileSize;
- (OSStatus)noteFileRenamed:(FSRef*)childRef fromName:(NSString*)oldName toName:(NSString*)newName;
- (NSString*)uniqueFilenameForTitle:(NSString*)title fromNote:(NoteObject*)note;
- (OSStatus)fileInNotesDirectory:(FSRef*)childRef isOwnedByUs:(BOOL*)owned hasCatalogInfo:(FSCatalogInfo *)info;
- (OSStatus)deleteFileInNotesDirectory:(FSRef*)childRef forFilename:(NSString*)filename;
- (OSStatus)createFileIfNotPresentInNotesDirectory:(FSRef*)childRef forFilename:(NSString*)filename fileWasCreated:(BOOL*)created;
- (OSStatus)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename destinationRef:(FSRef*)destRef;
- (OSStatus)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename destinationRef:(FSRef*)destRef 
							 verifyWithSelector:(SEL)verifySel verificationDelegate:(id)verifyDelegate;
+ (OSStatus)trashFolderRef:(FSRef*)trashRef forChild:(FSRef*)childRef;
- (OSStatus)moveFileToTrash:(FSRef *)childRef forFilename:(NSString*)filename;
- (void)notifyOfChangedTrash;
@end

@interface NSObject (NotationFileManagerDelegate)
- (NSNumber*)verifyDataAtTemporaryFSRef:(NSValue*)fsRefValue withFinalName:(NSString*)filename;
@end
