//
//  NotationFileManager.m
//  Notation
//
//  Created by Zachary Schneirov on 4/9/06.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import "NotationFileManager.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NSData_transformations.h"
#include <sys/param.h>
#include <sys/mount.h>

NSString *NotesDatabaseFileName = @"Notes & Settings";

@implementation NotationController (NotationFileManager)

static long getOptimalBlockSize(NotationController *controller);

OSStatus CreateDirectoryIfNotPresent(FSRef *parentRef, CFStringRef subDirectoryName, FSRef *childRef) {
    UniChar chars[256];
    
    OSStatus result;
    if ((result = FSRefMakeInDirectoryWithString(parentRef, childRef, subDirectoryName, chars))) {
		if (result == fnfErr) {
			result = FSCreateDirectoryUnicode (parentRef, CFStringGetLength(subDirectoryName),
											   chars, kFSCatInfoNone, NULL, childRef, NULL, NULL);
		}
		return result;
    }
    
    return noErr;
}

OSStatus CreateTemporaryFile(FSRef *parentRef, FSRef *childTempRef) {
    UniChar chars[256];
    unsigned int nameLength = 0;
    OSStatus result = noErr;
    
    do {
	CFStringRef filename = CreateRandomizedFileName();
	nameLength = CFStringGetLength(filename);
	result = FSRefMakeInDirectoryWithString(parentRef, childTempRef, filename, chars);
	CFRelease(filename);
	
    } while (result == noErr);
    
    if (result == fnfErr) {
	result = FSCreateFileUnicode(parentRef, nameLength, chars, kFSCatInfoNone, NULL, childTempRef, NULL);
    }
    
    
    return result;
}

static long getOptimalBlockSize(NotationController *controller) {
    struct statfs sfsb;
    OSStatus err = noErr;
    const UInt32 maxPathSize = 8 * 1024; //you can never have a large enough path buffer
    UInt8 *convertedPath = (UInt8*)malloc(maxPathSize * sizeof(UInt8));
    
    if ((err = FSRefMakePath(&(controller->noteDirectoryRef), convertedPath, maxPathSize)) == noErr) {
	
	if (!statfs((char*)convertedPath, &sfsb))
	    return sfsb.f_iosize;
	else
	    NSLog(@"statfs: error %d\n", errno);
    } else
	NSLog(@"FSRefMakePath: error %d\n", err);
    
    free(convertedPath);
    
    return 0;
}

long BlockSizeForNotation(NotationController *controller) {
    if (!controller->blockSize) {
	controller->blockSize = MAX(getOptimalBlockSize(controller), 16 * 1024);
    }
    
    return controller->blockSize;
}

- (OSStatus)refreshFileRefIfNecessary:(FSRef *)childRef withName:(NSString *)filename charsBuffer:(UniChar*)charsBuffer {
	BOOL isOwned = NO;
	if (IsZeros(childRef, sizeof(FSRef)) || [self fileInNotesDirectory:childRef isOwnedByUs:&isOwned hasCatalogInfo:NULL] != noErr || !isOwned) {
		OSStatus err = noErr;
		if ((err = FSRefMakeInDirectoryWithString(&noteDirectoryRef, childRef, (CFStringRef)filename, charsBuffer)) != noErr) {
			NSLog(@"Could not get an fsref for file with name %@: %d\n", filename, err);
			return err;
		}
    }
	return noErr;
}


- (BOOL)notesDirectoryIsTrashed {
	Boolean isInTrash = false;	
	if (FSDetermineIfRefIsEnclosedByFolder(0, kTrashFolderType, &noteDirectoryRef, &isInTrash) != noErr)
		isInTrash = false;
	return (BOOL)isInTrash;
}

- (BOOL)notesDirectoryContainsFile:(NSString*)filename returningFSRef:(FSRef*)childRef {
	UniChar chars[256];
	if (!filename) return NO;
	
	return FSRefMakeInDirectoryWithString(&noteDirectoryRef, childRef, (CFStringRef)filename, chars) == noErr;
}

- (OSStatus)renameAndForgetNoteDatabaseFile:(NSString*)newfilename {
	//this method does not move the note database file; for now it is used in cases of upgrading incompatible files
	
	UniChar chars[256];
    OSStatus err = noErr;	
	CFRange range = {0, CFStringGetLength((CFStringRef)newfilename)};
    CFStringGetCharacters((CFStringRef)newfilename, range, chars);
    
    if ((err = FSRenameUnicode(&noteDatabaseRef, range.length, chars, kTextEncodingDefaultFormat, NULL)) != noErr) {
		NSLog(@"Error renaming notes database file to %@: %d", newfilename, err);
		return err;
    }
	//reset the FSRef to ensure it doesn't point to the renamed file
	bzero(&noteDatabaseRef, sizeof(FSRef));
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
		
		if ([openPanel runModal] == NSOKButton) {
			CFStringRef filename = (CFStringRef)[openPanel filename];
			if (filename) {
				
				FSRef newParentRef;
				CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, filename, kCFURLPOSIXPathStyle, true);
				[(id)url autorelease];
				if (!url || !CFURLGetFSRef(url, &newParentRef)) {
					NSRunAlertPanel(NSLocalizedString(@"Unable to create an FSRef from the chosen directory.",nil), 
									NSLocalizedString(@"Your notes were not moved.",nil), NSLocalizedString(@"OK",nil), NULL, NULL);
					continue;
				}
				
				FSRef newNotesDirectory;
				OSErr err = FSMoveObject(&noteDirectoryRef,  &newParentRef, &newNotesDirectory);
				if (err != noErr) {
					NSRunAlertPanel([NSString stringWithFormat:NSLocalizedString(@"Couldn't move notes into the chosen folder because %@",nil), 
						[NSString reasonStringFromCarbonFSError:err]], NSLocalizedString(@"Your notes were not moved.",nil), NSLocalizedString(@"OK",nil), NULL, NULL);
					continue;
				}
				
				if (FSCompareFSRefs(&noteDirectoryRef, &newNotesDirectory) != noErr) {
					NSData *aliasData = [NSData aliasDataForFSRef:&newNotesDirectory];
					if (aliasData) [[GlobalPrefs defaultPrefs] setAliasDataForDefaultDirectory:aliasData sender:self];
					//we must quit now, as notes will very likely be re-initialized in the same place
					goto terminate;
				}
				
				//directory move successful! //show the user where new notes are
				NSString *newNotesPath = [NSString pathWithFSRef:&newNotesDirectory];
				if (newNotesPath) [[NSWorkspace sharedWorkspace] selectFile:newNotesPath inFileViewerRootedAtPath:nil];
				
				break;
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

+ (OSStatus)getDefaultNotesDirectoryRef:(FSRef*)notesDir {
    FSRef appSupportFoundRef;
    
    OSErr err = FSFindFolder(kUserDomain, kApplicationSupportFolderType, kCreateFolder, &appSupportFoundRef);
    if (err != noErr) {
	NSLog(@"Unable to locate or create an Application Support directory: %d", err);
	return err;
    } else {
	//now try to get Notational Database directory
	if ((err = CreateDirectoryIfNotPresent(&appSupportFoundRef, (CFStringRef)@"Notational Data", notesDir)) != noErr) {
	    
	    return err;
	}
    }
    return noErr;
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
	
	//use the note's current format if the current default format is for a database
	int defaultFormat = [notationPrefs notesStorageFormat];
	NSString *extension = [NotationPrefs pathExtensionForFormat:(defaultFormat || !note ? defaultFormat : storageFormatOfNote(note))];
	
	//assume that we won't have more than 999 notes with the exact same name and of more than 247 chars
	uniqueFilename = [uniqueFilename filenameExpectingAdditionalCharCount:3 + [extension length] + 2];
	
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

- (OSStatus)noteFileRenamed:(FSRef*)childRef fromName:(NSString*)oldName toName:(NSString*)newName {
    if (![self currentNoteStorageFormat])
		return noErr;
    
    UniChar chars[256];
    
    OSStatus err = [self refreshFileRefIfNecessary:childRef withName:oldName charsBuffer:chars];
	if (noErr != err) return err;
    
    CFRange range = {0, CFStringGetLength((CFStringRef)newName)};
    CFStringGetCharacters((CFStringRef)newName, range, chars);
    
    if ((err = FSRenameUnicode(childRef, range.length, chars, kTextEncodingDefaultFormat, childRef)) != noErr) {
		NSLog(@"Error renaming file %@ to %@: %d", oldName, newName, err);
		return err;
    }
    
    return noErr;
}

- (OSStatus)fileInNotesDirectory:(FSRef*)childRef isOwnedByUs:(BOOL*)owned hasCatalogInfo:(FSCatalogInfo *)info {
    FSRef parentRef;
    FSCatalogInfoBitmap whichInfo = kFSCatInfoNone;
    
    if (owned) *owned = NO;
    
    if (info) {
		whichInfo = kFSCatInfoContentMod | kFSCatInfoCreateDate | kFSCatInfoNodeID | kFSCatInfoDataSizes;
		//may have to be adjusted to include logical size if we start tracking that
		bzero(info, sizeof(FSCatalogInfo));
    }
    
    OSStatus err = noErr;
    
    if ((err = FSGetCatalogInfo(childRef, whichInfo, info, NULL, NULL, &parentRef)) != noErr)
	return err;
    
    if (owned) *owned = (FSCompareFSRefs(&parentRef, &noteDirectoryRef) == noErr);
    
    return noErr;
}

- (OSStatus)deleteFileInNotesDirectory:(FSRef*)childRef forFilename:(NSString*)filename {
    UniChar chars[256];
    OSStatus err = [self refreshFileRefIfNecessary:childRef withName:filename charsBuffer:chars];
    if (noErr != err) return err;

	if ((err = FSDeleteObject(childRef)) != noErr) {
		NSLog(@"Error deleting file: %d", err);
		return err;
	}
    
    return noErr;
}

- (NSMutableData*)dataFromFileInNotesDirectory:(FSRef*)childRef forFilename:(NSString*)filename {
    return [self dataFromFileInNotesDirectory:childRef forFilename:filename fileSize:0];
}

- (NSMutableData*)dataFromFileInNotesDirectory:(FSRef*)childRef forCatalogEntry:(NoteCatalogEntry*)catEntry {
    return [self dataFromFileInNotesDirectory:childRef forFilename:(NSString*)catEntry->filename fileSize:catEntry->logicalSize];
}

- (NSMutableData*)dataFromFileInNotesDirectory:(FSRef*)childRef forFilename:(NSString*)filename fileSize:(UInt64)givenFileSize {
	
    UInt64 fileSize = givenFileSize;
    char *notesDataPtr = NULL;
    
	UniChar chars[256];
	OSStatus err = [self refreshFileRefIfNecessary:childRef withName:filename charsBuffer:chars];
	if (noErr != err) return nil;
	
    if ((err = FSRefReadData(childRef, BlockSizeForNotation(self), &fileSize, (void**)&notesDataPtr, noCacheMask)) != noErr) {
		NSLog(@"%s: error %d", _cmd, err);
		return nil;
	}    
    if (!notesDataPtr)
		return nil;
    
    return [[[NSMutableData alloc] initWithBytesNoCopy:notesDataPtr length:fileSize freeWhenDone:YES] autorelease];
}

- (OSStatus)createFileIfNotPresentInNotesDirectory:(FSRef*)childRef forFilename:(NSString*)filename fileWasCreated:(BOOL*)created {
	
	return FSCreateFileIfNotPresentInDirectory(&noteDirectoryRef, childRef, (CFStringRef)filename, (Boolean*)created);
}

- (OSStatus)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename destinationRef:(FSRef*)destRef {
	return [self storeDataAtomicallyInNotesDirectory:data withName:filename destinationRef:destRef verifyWithSelector:NULL verificationDelegate:nil];
}

//either name or destRef must be valid; destRef is declared invalid by filling the struct with 0

- (OSStatus)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename destinationRef:(FSRef*)destRef 
							 verifyWithSelector:(SEL)verificationSel verificationDelegate:(id)verifyDelegate {
    OSStatus err = noErr;
    	
	FSRef tempFileRef;
    if ((err = CreateTemporaryFile(&noteDirectoryRef, &tempFileRef)) != noErr) {
		NSLog(@"error creating temporary file: %d", err);
		return err;
    }
    
    //now write to temporary file and swap
    if ((err = FSRefWriteData(&tempFileRef, BlockSizeForNotation(self), [data length], [data bytes], pleaseCacheMask, false)) != noErr) {
		NSLog(@"error writing to temporary file: %d", err);
		
		return err;
    }
	
	//before we try to swap the data contents of this temp file with the (possibly even soon-to-be-created) Notes & Settings file,
	//try to read it back and see if it can be decrypted and decoded:
	if (verifyDelegate && verificationSel) {
		if (noErr != (err = [[verifyDelegate performSelector:verificationSel withObject:[NSValue valueWithPointer:&tempFileRef] withObject:filename] intValue])) {
			NSLog(@"couldn't verify written notes, so not continuing to save");
			(void)FSDeleteObject(&tempFileRef);
			return err;
		}
	}
    
	//don't try to make a new fsref if the file is still inside notes folder, but perhaps under a different name
	BOOL isOwned = NO;
	if (IsZeros(destRef,sizeof(FSRef)) || [self fileInNotesDirectory:destRef isOwnedByUs:&isOwned hasCatalogInfo:NULL] != noErr || !isOwned) {
		
		if ((err = [self createFileIfNotPresentInNotesDirectory:destRef forFilename:filename fileWasCreated:nil]) != noErr) {
			NSLog(@"error creating or getting fsref for file %@: %d", filename, err);
			return err;
		}
    }
    //if destRef is not zeros, just assume that it exists and retry if it doesn't
	FSRef newSourceRef, newDestRef;
	
	if (volumeSupportsExchangeObjects == -1)
		volumeSupportsExchangeObjects = VolumeOfFSRefSupportsExchangeObjects(&tempFileRef);
	if (!volumeSupportsExchangeObjects) {
		//NSLog(@"emulating fsexchange objects");
		if ((err = FSExchangeObjectsEmulate(&tempFileRef, destRef, &newSourceRef, &newDestRef)) == noErr) {
			memcpy(&tempFileRef, &newSourceRef, sizeof(FSRef));
			memcpy(destRef, &newDestRef, sizeof(FSRef));
		}
	} else {
		err = FSExchangeObjects(&tempFileRef, destRef);
	}
		
    if (err != noErr) {
		NSLog(@"error exchanging contents of temporary file with destination file %@: %d",filename, err);
		return err;
    }
    
    if ((err = FSDeleteObject(&tempFileRef)) != noErr) {
		NSLog(@"Error deleting temporary file: %d; moving to trash", err);
		if ((err = [self moveFileToTrash:&tempFileRef forFilename:nil]) != noErr)
			NSLog(@"Error moving file to trash: %d\n", err);
    }
    
    return noErr;
}


- (void)notifyOfChangedTrash {
	FSRef folder;
	
	OSStatus err = [NotationController trashFolderRef:&folder forChild:&noteDirectoryRef];
	
	if (err == noErr)
		FNNotify(&folder, kFNDirectoryModifiedMessage, kNilOptions);
	 else
		NSLog(@"notifyOfChangedTrash: error getting trash: %d", err);
	
	 NSString *sillyDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[(NSString*)CreateRandomizedFileName() autorelease]];
	 [[NSFileManager defaultManager] createDirectoryAtPath:sillyDirectory attributes:nil];
	 NSInteger tag = 0;
	 [[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation source:NSTemporaryDirectory() destination:@"" 
												   files:[NSArray arrayWithObject:[sillyDirectory lastPathComponent]] tag:&tag];
}

+ (OSStatus)trashFolderRef:(FSRef*)trashRef forChild:(FSRef*)childRef {
    FSVolumeRefNum volume = kOnAppropriateDisk;
    FSCatalogInfo info;
    // get the volume the file resides on and use this as the base for finding the trash folder
    // since each volume will contain its own trash folder...
    
    if (FSGetCatalogInfo(childRef, kFSCatInfoVolume, &info, NULL, NULL, NULL) == noErr)
		volume = info.volume;
    // go ahead and find the trash folder on that volume.
    // the trash folder for the current user may not yet exist on that volume, so ask to automatically create it

	return FSFindFolder(volume, kTrashFolderType, kCreateFolder, trashRef);
}

- (OSStatus)moveFileToTrash:(FSRef *)childRef forFilename:(NSString*)filename {
	UniChar chars[256];
    
	OSStatus err = [self refreshFileRefIfNecessary:childRef withName:filename charsBuffer:chars];
	if (noErr != err) return err;
		
	FSRef folder;
	if ([NotationController trashFolderRef:&folder forChild:childRef] != noErr)
		return err;
	
	err = FSMoveObject(childRef, &folder, NULL);
	if (err == dupFNErr) {
		// try to rename the duplicate file in the trash
		
		HFSUniStr255 name;
		
		err = FSGetCatalogInfo(childRef, kFSCatInfoNone, NULL, &name, NULL, NULL);
		if (err == noErr) {
			UInt16 origLen = name.length;
			if (origLen > 245)
				origLen = 245;
			
			FSRef duplicateFile;
			err = FSMakeFSRefUnicode(&folder, name.length, name.unicode, kTextEncodingUnknown, &duplicateFile);
			int i = 1, j;
			while (1) {
				i++;
				// attempt to create new unique name
				HFSUniStr255 newName = name;
				char num[16];
				int numLen;
				
				numLen = sprintf(num, "%d", i);
				newName.unicode[origLen] = ' ';
				for (j=0; j < numLen; j++)
					newName.unicode[origLen + j + 1] = num[j];
				newName.length = origLen + numLen + 1;
				
				err = FSRenameUnicode(&duplicateFile, newName.length, newName.unicode, kTextEncodingUnknown, NULL);
				if (err != dupFNErr)
					break;
			}    
			if (err == noErr)
				err = FSMoveObject(childRef, &folder, NULL);    
		}
	}
	
	if (err == noErr) {
		FSCatalogInfo catInfo;
		
		CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
		err = UCConvertCFAbsoluteTimeToUTCDateTime(now, &catInfo.contentModDate);
		if (err == noErr)
			err = FSSetCatalogInfo(&noteDirectoryRef, kFSCatInfoContentMod, &catInfo);
		if (err) {
			NSLog(@"couldn't touch modification date of file's parent folder: error %d", err);
			err = noErr;
		}
	}
    
    return err;
}

@end
