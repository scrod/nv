//
//  NotationFileManager.h
//  Notation
//
//  Created by Zachary Schneirov on 4/9/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "NotationController.h"
#include "FSExchangeObjectsCompat.h"
#import "BufferUtils.h"

extern NSString *NotesDatabaseFileName;

@interface NotationController (NotationFileManager)

OSStatus CreateTemporaryFile(FSRef *parentRef, FSRef *childTempRef);
OSStatus CreateDirectoryIfNotPresent(FSRef *parentRef, CFStringRef subDirectoryName, FSRef *childRef);
long BlockSizeForNotation(NotationController *controller);

- (BOOL)notesDirectoryIsTrashed;
- (BOOL)notesDirectoryContainsFile:(NSString*)filename returningFSRef:(FSRef*)childRef;

- (OSStatus)renameAndForgetNoteDatabaseFile:(NSString*)newfilename;

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
