//
//  NotationFileManager.m
//  Notation
//
//  Created by Zachary Schneirov on 4/9/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import "NotationFileManager.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NSData_transformations.h"
#include <sys/param.h>
#include <sys/mount.h>


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


#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
OSErr FSDetermineIfRefIsEnclosedByFolder(short domainOrVRefNum, OSType folderType, const FSRef *inRef, Boolean *outResult);
#endif

- (BOOL)notesDirectoryIsTrashed {
	Boolean isInTrash = false;
	
	if (FSDetermineIfRefIsEnclosedByFolder == NULL) {
		FSCatalogInfo info;
		FSRef workingRef;
		
		memmove(&workingRef, &noteDirectoryRef, sizeof(FSRef));
		
		while (FSGetCatalogInfo(&workingRef, kFSCatInfoVolume | kFSCatInfoParentDirID,
								&info, NULL, NULL, &workingRef) == noErr) {
			FolderType folderType;
			
			if (IdentifyFolder(info.volume, info.parentDirID, &folderType) != noErr)
				break;
			
			if (folderType == kTrashFolderType || 
				folderType == kWhereToEmptyTrashFolderType ||
				folderType == kSystemTrashFolderType) {
				isInTrash = true;
				break;
			}
			
			if (info.parentDirID == fsRtDirID)
				break;
		}
	} else {
		if (FSDetermineIfRefIsEnclosedByFolder(0, kTrashFolderType, &noteDirectoryRef, &isInTrash) != noErr)
			isInTrash = false;
	}
	
	return (BOOL)isInTrash;
}


- (BOOL)notesDirectoryContainsFile:(NSString*)filename returningFSRef:(FSRef*)childRef {
	UniChar chars[256];
	if (!filename) return NO;
	
	return FSRefMakeInDirectoryWithString(&noteDirectoryRef, childRef, (CFStringRef)filename, chars) == noErr;
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
	NSMutableString *sanitizedName = [uniqueFilename stringByReplacingOccurrencesOfString:@":" withString:@"-"];
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
    
    BOOL secondAttempt = NO;
    OSStatus err = noErr;
    
    if (IsZeros(childRef,sizeof(FSRef))) {
regenerateFSRef:    
		if ((err = FSRefMakeInDirectoryWithString(&noteDirectoryRef, childRef, (CFStringRef)oldName, chars)) != noErr) {
			NSLog(@"Could not get an fsref for file with name %@: %d\n", oldName, err);
			return err;
		}
    }
    
    CFRange range = {0, CFStringGetLength((CFStringRef)newName)};
    CFStringGetCharacters((CFStringRef)newName, range, chars);
    
    if ((err = FSRenameUnicode(childRef, range.length, chars, kTextEncodingDefaultFormat, childRef)) != noErr) {
		if (err == fnfErr && !secondAttempt) {
			secondAttempt = YES;
			goto regenerateFSRef;
		}
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
		whichInfo = kFSCatInfoContentMod | kFSCatInfoCreateDate | kFSCatInfoNodeID;
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
    BOOL secondAttempt = NO;
    OSStatus err = noErr;
    
    if (IsZeros(childRef,sizeof(FSRef))) {
	
regenerateFSRef:
	
	if ((err = FSRefMakeInDirectoryWithString(&noteDirectoryRef, childRef, (CFStringRef)filename, chars)) != noErr) {
	    NSLog(@"Could not get an fsref for file with name %@: %d\n", filename, err);
	    return err;
	}
    }
    
    //check that it's actually _in_ the notes directory first
    
    BOOL isInOurDirectory = NO;
    if ((err = [self fileInNotesDirectory:childRef isOwnedByUs:&isInOurDirectory hasCatalogInfo:NULL]) != noErr) {
	if (err == fnfErr && !secondAttempt) {
	    secondAttempt = YES;
	    goto regenerateFSRef;
	}
	NSLog(@"Couldn't get FSRef ref for parent of file %@: %d", filename, err);
	return err;
    }
    
    if (isInOurDirectory) {
	if ((err = FSDeleteObject(childRef)) != noErr) {
	    NSLog(@"Error deleting file: %d", err);
	    return err;
	}
    } else {
	NSLog(@"not deleting because %@ was moved!", filename);
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
    //read from fsref; if it doesn't exist, then try to re-create the fsref based on filename
    
    UInt64 fileSize = givenFileSize;
    char *notesDataPtr = NULL;
    BOOL secondAttempt = NO;
    
    UniChar chars[256];
    OSStatus err = noErr;
    
    if (IsZeros(childRef,sizeof(FSRef))) {
	
regenerateFSRef:
	
	if ((err = FSRefMakeInDirectoryWithString(&noteDirectoryRef, childRef, (CFStringRef)filename, chars)) != noErr) {
	    NSLog(@"Could not get an fsref for file with name %@: %d\n", filename, err);
	    return nil;
	}
    }
    
    err = FSRefReadData(childRef, BlockSizeForNotation(self), &fileSize, (void**)&notesDataPtr, 0);
    if (err == fnfErr && !secondAttempt) {
	//in case the file pointed to by childRef was deleted and then recreated before we could respond to the changes
	
	secondAttempt = YES;
	goto regenerateFSRef;
    } else if (err != noErr) {
	
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
    if ((err = FSRefWriteData(&tempFileRef, BlockSizeForNotation(self), [data length], [data bytes], 0, false)) != noErr) {
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
    
    BOOL retriedCreation = NO;
    
    if (IsZeros(destRef,sizeof(FSRef))) {
attemptToCreateFile:
		
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
		if (err == fnfErr && !retriedCreation) {
			//sorry, Dijkstra
			retriedCreation = YES;
			goto attemptToCreateFile;
		} else {
			NSLog(@"error exchanging contents of temporary file with destination file %@: %d",filename, err);
			return err;
		}
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
    OSErr err = noErr;
	BOOL secondAttempt = NO, owned = NO;
	UniChar chars[256];
    
    if (filename && IsZeros(childRef,sizeof(FSRef))) {
regenerateFSRef:
		if ((err = FSRefMakeInDirectoryWithString(&noteDirectoryRef, childRef, (CFStringRef)filename, chars)) != noErr) {
			NSLog(@"Could not get an fsref for file with name %@: %d\n", filename, err);
			return err;
		}
		NSLog(@"regen-ratin'");
    }

	if ((err = [self fileInNotesDirectory:childRef isOwnedByUs:&owned hasCatalogInfo:NULL]) != noErr) {
		if (err == fnfErr && !secondAttempt && filename) {
			secondAttempt = YES;
			goto regenerateFSRef;
		}
		NSLog(@"Error finding file %@ to trash: %d", filename ? filename : @"(not given)", err);
		return err;
	}
	
	if (owned) {
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
				printf("couldn't touch modification date of file's parent folder: error %d\n", err);
				err = noErr;
			}
		}
	} else {
		NSLog(@"File doesn't seem to be owned by us/exist, so not trashing");
	}
    
    return err;
}

@end
