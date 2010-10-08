//
//  NotationDirectoryManager.m
//  Notation
//
//  Created by Zachary Schneirov on 12/10/09.

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

#import "NotationDirectoryManager.h"
#import "NotationPrefs.h"
#import "GlobalPrefs.h"
#import "NotationSyncServiceManager.h"
#import "NoteObject.h"
#import "DeletionManager.h"
#import "NSCollection_utils.h"

#define kMaxFileIteratorCount 100

@implementation NotationController (NotationDirectoryManager)


NSInteger compareCatalogEntryName(const void *one, const void *two) {
    return (int)CFStringCompare((CFStringRef)((*(NoteCatalogEntry **)one)->filename), 
								(CFStringRef)((*(NoteCatalogEntry **)two)->filename), kCFCompareCaseInsensitive);
}

NSInteger compareCatalogValueNodeID(id *a, id *b) {
	NoteCatalogEntry* aEntry = (NoteCatalogEntry*)[*(id*)a pointerValue];
	NoteCatalogEntry* bEntry = (NoteCatalogEntry*)[*(id*)b pointerValue];
	
    return aEntry->nodeID - bEntry->nodeID;
}

NSInteger compareCatalogValueFileSize(id *a, id *b) {
	NoteCatalogEntry* aEntry = (NoteCatalogEntry*)[*(id*)a pointerValue];
	NoteCatalogEntry* bEntry = (NoteCatalogEntry*)[*(id*)b pointerValue];
	
    return aEntry->logicalSize - bEntry->logicalSize;
}


//used to find notes corresponding to a group of existing files in the notes dir, with the understanding 
//that the files' contents are up-to-date and the filename property of the note objs is also up-to-date
//e.g. caller should know that if notes are stored as a single DB, then the file could still be out-of-date
- (NSSet*)notesWithFilenames:(NSArray*)filenames unknownFiles:(NSArray**)unknownFiles {
	//intersects a list of filenames with the current set of available notes
	
	NSUInteger i = 0;
	
	NSMutableDictionary *lcNamesDict = [NSMutableDictionary dictionaryWithCapacity:[filenames count]];
	for (i=0; i<[filenames count]; i++) {
		NSString *path = [filenames objectAtIndex:i];
		//assume that paths are of NSFileManager origin, not Carbon File Manager
		//(note filenames are derived with the expectation of matching against Carbon File Manager)
		[lcNamesDict setObject:path forKey:[[[path lastPathComponent] lowercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"/"]];
	}
	
	NSMutableSet *foundNotes = [NSMutableSet setWithCapacity:[filenames	count]];
	
	for (i=0; i<[allNotes count]; i++) {
		NoteObject *aNote = [allNotes objectAtIndex:i];
		NSString *existingRequestedFilename = [filenameOfNote(aNote) lowercaseString];
		if (existingRequestedFilename && [lcNamesDict objectForKey:existingRequestedFilename]) {
			[foundNotes addObject:aNote];
			//remove paths from the dict as they are matched to existing notes; those left over will be new ("unknown") files
			[lcNamesDict removeObjectForKey:existingRequestedFilename];
		}
	}
	if (unknownFiles) *unknownFiles = [lcNamesDict allValues];
	return foundNotes;
}


- (void)stopFileNotifications {
	OSStatus err = noErr;
    if (!IsZeros(&noteDirSubscription, sizeof(FNSubscriptionRef))) {
		
		if ((err = FNUnsubscribe(noteDirSubscription)) != noErr) {
			NSLog(@"Could not unsubscribe from note changes callback: %d", err);
		} else {
			bzero(&noteDirSubscription, sizeof(FNSubscriptionRef));
		}
		
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNotesFromDirectory) object:nil];
    }
    
}

void NotesDirFNSubscriptionProc(FNMessage message, OptionBits flags, void * refcon, FNSubscriptionRef subscription) {
    //this only works for the Finder and perhaps the navigation manager right now
    if (kFNDirectoryModifiedMessage == message) {
		//NSLog(@"note directory changed");
		if (refcon) {
			[NSObject cancelPreviousPerformRequestsWithTarget:(id)refcon selector:@selector(synchronizeNotesFromDirectory) object:nil];
			[(id)refcon performSelector:@selector(synchronizeNotesFromDirectory) withObject:nil afterDelay:0.0];
		}
		
    } else {
		NSLog(@"we received an FNSubscr. callback and the directory didn't actually change?");
    }
}


- (BOOL)synchronizeNotesFromDirectory {
    if ([self currentNoteStorageFormat] == SingleDatabaseFormat) {
		//NSLog(@"%s: called when storage format is singledatabase", _cmd);
		return NO;
	}
	
    //NSDate *date = [NSDate date];
    if ([self _readFilesInDirectory]) {
		//NSLog(@"read files in directory");
		
		directoryChangesFound = NO;
		if (catEntriesCount && [allNotes count]) {
			[self makeNotesMatchCatalogEntries:sortedCatalogEntries ofSize:catEntriesCount];
		} else {
			unsigned int i;
			
			if (![allNotes count]) {
				//no notes exist, so every file must be new
				for (i=0; i<catEntriesCount; i++) {
					if ([notationPrefs catalogEntryAllowed:sortedCatalogEntries[i]])
						[self addNoteFromCatalogEntry:sortedCatalogEntries[i]];
				}
			}
			
			if (!catEntriesCount) {
				//there is nothing at all in the directory, so remove all the notes
				//we probably shouldn't get here; there should be at least a database file and random .DS_Store-like crap
				[deletionManager addDeletedNotes:allNotes];
			}
		}
		
		if (directoryChangesFound) {
			[self resortAllNotes];
		    [self refilterNotes];
		}
		
		//NSLog(@"file sync time: %g, ",[[NSDate date] timeIntervalSinceDate:date]);
		return YES;
    }
    
    return NO;
}

//scour the notes directory for fresh meat
- (BOOL)_readFilesInDirectory {
    
    OSStatus status = noErr;
    FSIterator dirIterator;
    ItemCount totalObjects = 0, dirObjectCount = 0;
    unsigned int i = 0, catIndex = 0;
    
    //something like 16 VM pages used here?
    if (!fsCatInfoArray) fsCatInfoArray = (FSCatalogInfo *)calloc(kMaxFileIteratorCount, sizeof(FSCatalogInfo));
    if (!HFSUniNameArray) HFSUniNameArray = (HFSUniStr255 *)calloc(kMaxFileIteratorCount, sizeof(HFSUniStr255));
	
    if ((status = FSOpenIterator(&noteDirectoryRef, kFSIterateFlat, &dirIterator)) == noErr) {
		//catEntriesCount = 0;
		
        do {
            // Grab a batch of source files to process from the source directory
            status = FSGetCatalogInfoBulk(dirIterator, kMaxFileIteratorCount, &dirObjectCount, NULL,
										  kFSCatInfoNodeFlags | kFSCatInfoFinderInfo | kFSCatInfoContentMod | kFSCatInfoDataSizes | kFSCatInfoNodeID,
										  fsCatInfoArray, NULL, NULL, HFSUniNameArray);
			
            if ((status == errFSNoMoreItems || status == noErr) && dirObjectCount) {
                status = noErr;
				
				totalObjects += dirObjectCount;
				if (totalObjects > totalCatEntriesCount) {
					unsigned int oldCatEntriesCount = totalCatEntriesCount;
					
					totalCatEntriesCount = totalObjects;
					catalogEntries = (NoteCatalogEntry *)realloc(catalogEntries, totalObjects * sizeof(NoteCatalogEntry));
					sortedCatalogEntries = (NoteCatalogEntry **)realloc(sortedCatalogEntries, totalObjects * sizeof(NoteCatalogEntry*));
					
					//clear unused memory to make filename and filenameChars null
					
					size_t newSpace = (totalCatEntriesCount - oldCatEntriesCount) * sizeof(NoteCatalogEntry);
					bzero(catalogEntries + oldCatEntriesCount, newSpace);
				}
				
				for (i = 0; i < dirObjectCount; i++) {
					// Only read files, not directories
					if (!(fsCatInfoArray[i].nodeFlags & kFSNodeIsDirectoryMask)) { 
						//filter these only for files that will be added
						//that way we can catch changes in files whose format is still being lazily updated
						
						NoteCatalogEntry *entry = &catalogEntries[catIndex];
						HFSUniStr255 *filename = &HFSUniNameArray[i];
						
						entry->fileType = ((FileInfo *)fsCatInfoArray[i].finderInfo)->fileType;
						entry->logicalSize = (UInt32)(fsCatInfoArray[i].dataLogicalSize & 0xFFFFFFFF);
						entry->nodeID = (UInt32)fsCatInfoArray[i].nodeID;
						entry->lastModified = fsCatInfoArray[i].contentModDate;
						
						if (filename->length > entry->filenameCharCount) {
							entry->filenameCharCount = filename->length;
							entry->filenameChars = (UniChar*)realloc(entry->filenameChars, entry->filenameCharCount * sizeof(UniChar));
						}
						
						memcpy(entry->filenameChars, filename->unicode, filename->length * sizeof(UniChar));
						
						if (!entry->filename)
							entry->filename = CFStringCreateMutableWithExternalCharactersNoCopy(NULL, entry->filenameChars, filename->length, entry->filenameCharCount, kCFAllocatorNull);
						else
							CFStringSetExternalCharactersNoCopy(entry->filename, entry->filenameChars, filename->length, entry->filenameCharCount);
						
						// mipe: Normalize the filename to make sure that it will be found regardless of international characters
						CFStringNormalize(entry->filename, kCFStringNormalizationFormC);

						catIndex++;
                    }
                }
				
				catEntriesCount = catIndex;
            }
            
        } while (status == noErr);
		
		FSCloseIterator(dirIterator);
		
		for (i=0; i<catEntriesCount; i++) {
			sortedCatalogEntries[i] = &catalogEntries[i];
		}
		
		return YES;
    }
    
    NSLog(@"Error opening FSIterator: %d", status);
    
    return NO;
}

- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry {
	//check dates
	UTCDateTime lastReadDate = fileModifiedDateOfNote(aNoteObject);
	UTCDateTime fileModDate = catEntry->lastModified;
	
	//should we always update the note's stored inode here regardless?
	
	if (fileSizeOfNote(aNoteObject) != catEntry->logicalSize ||
		lastReadDate.lowSeconds != fileModDate.lowSeconds ||
		lastReadDate.highSeconds != fileModDate.highSeconds ||
		lastReadDate.fraction != fileModDate.fraction) {
		//assume the file on disk was modified by someone other than us
		
		//figure out whether there is a conflict; is this file on disk older than the one that we have in memory? do we merge?
		//if ((UInt64*)&fileModDate > (UInt64*)&lastReadDate)
		
		//check if this note has changes in memory that still need to be committed -- that we _know_ the other writer never had a chance to see
		if (![unwrittenNotes containsObject:aNoteObject]) {
			
			if (![aNoteObject updateFromCatalogEntry:catEntry]) {
				NSLog(@"file %@ was modified but could not be updated", catEntry->filename);
				//return NO;
			}
			//do not call makeNoteDirty because use of the WAL in this instance would cause redundant disk activity
			//in the event of a crash this change could still be recovered; 
			
			[aNoteObject registerModificationWithOwnedServices];
			[self schedulePushToAllSyncServicesForNote:aNoteObject];
			
			[self note:aNoteObject attributeChanged:NotePreviewString]; //reverse delegate?
			
			[delegate contentsUpdatedForNote:aNoteObject];
			
			[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:NoteDateModifiedColumnString afterDelay:0.0];
			
			notesChanged = YES;
			NSLog(@"FILE WAS MODIFIED: %@", catEntry->filename);
			
			return YES;
		} else {
			//it's a conflict! we win.
			NSLog(@"%@ was modified with unsaved changes in NV! Deciding the conflict in favor of NV.", catEntry->filename); 
		}
		
	}
	
	return NO;
}

- (void)makeNotesMatchCatalogEntries:(NoteCatalogEntry**)catEntriesPtrs ofSize:(size_t)catCount {
    
    unsigned int aSize = [allNotes count];
    unsigned int bSize = catCount;
    
	ResizeBuffer((void***)&allNotesBuffer, aSize, &allNotesBufferSize);
	
	assert(allNotesBuffer != NULL);
	
    NoteObject **currentNotes = allNotesBuffer;
    [allNotes getObjects:(id*)currentNotes];
	
	mergesort((void *)allNotesBuffer, (size_t)aSize, sizeof(id), (int (*)(const void *, const void *))compareFilename);
	mergesort((void *)catEntriesPtrs, (size_t)bSize, sizeof(NoteCatalogEntry*), (int (*)(const void *, const void *))compareCatalogEntryName);
	
    NSMutableArray *addedEntries = [NSMutableArray array];
    NSMutableArray *removedEntries = [NSMutableArray array];
	
    //oldItems(a,i) = currentNotes
    //newItems(b,j) = catEntries;
    
    unsigned int i, j, lastInserted = 0;
    
    for (i=0; i<aSize; i++) {
		
		BOOL exitedEarly = NO;
		for (j=lastInserted; j<bSize; j++) {
			
			CFComparisonResult order = CFStringCompare((CFStringRef)(catEntriesPtrs[j]->filename),
													   (CFStringRef)filenameOfNote(currentNotes[i]), 
													   kCFCompareCaseInsensitive);
			if (order == kCFCompareGreaterThan) {    //if (A[i] < B[j])
				lastInserted = j;
				exitedEarly = YES;
				
				//NSLog(@"FILE DELETED (during): %@", filenameOfNote(currentNotes[i]));
				[removedEntries addObject:currentNotes[i]];
				break;
			} else if (order == kCFCompareEqualTo) {			//if (A[i] == B[j])
				//the name matches, so add this to changed iff its contents also changed
				lastInserted = j + 1;
				exitedEarly = YES;
				
				[self modifyNoteIfNecessary:currentNotes[i] usingCatalogEntry:catEntriesPtrs[j]];
				
				break;
			}
			
			//NSLog(@"FILE ADDED (during): %@", catEntriesPtrs[j]->filename);
			if ([notationPrefs catalogEntryAllowed:catEntriesPtrs[j]])
				[addedEntries addObject:[NSValue valueWithPointer:catEntriesPtrs[j]]];
		}
		
		if (!exitedEarly) {
			
			//element A[i] "appended" to the end of list B
			if (CFStringCompare((CFStringRef)filenameOfNote(currentNotes[i]),
								(CFStringRef)(catEntriesPtrs[MIN(lastInserted, bSize-1)]->filename), 
								kCFCompareCaseInsensitive) == kCFCompareGreaterThan) {
				lastInserted = bSize;
				
				//NSLog(@"FILE DELETED (after): %@", filenameOfNote(currentNotes[i]));
				[removedEntries addObject:currentNotes[i]];
			}
		}
		
    }
    
    for (j=lastInserted; j<bSize; j++) {
		
		//NSLog(@"FILE ADDED (after): %@", catEntriesPtrs[j]->filename);
		if ([notationPrefs catalogEntryAllowed:catEntriesPtrs[j]])
			[addedEntries addObject:[NSValue valueWithPointer:catEntriesPtrs[j]]];
    }
    
	if ([addedEntries count] && [removedEntries count]) {
		[self processNotesAddedByCNID:addedEntries removed:removedEntries];
	} else {
		
		if (![removedEntries count]) {
			for (i=0; i<[addedEntries count]; i++) {
				[self addNoteFromCatalogEntry:(NoteCatalogEntry*)[[addedEntries objectAtIndex:i] pointerValue]];
			}
		}
		
		if (![addedEntries count]) {			
			[deletionManager addDeletedNotes:removedEntries];
		}
	}
	
}

//find renamed notes through unique file IDs
- (void)processNotesAddedByCNID:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	unsigned int aSize = [removedEntries count], bSize = [addedEntries count];
    
    //sort on nodeID here
	[addedEntries sortUnstableUsingFunction:compareCatalogValueNodeID];
	[removedEntries sortUnstableUsingFunction:compareNodeID];
	
	NSMutableArray *hfsAddedEntries = [NSMutableArray array];
	NSMutableArray *hfsRemovedEntries = [NSMutableArray array];
	
    //oldItems(a,i) = currentNotes
    //newItems(b,j) = catEntries;
    
    unsigned int i, j, lastInserted = 0;
    
    for (i=0; i<aSize; i++) {
		NoteObject *currentNote = [removedEntries objectAtIndex:i];
		
		BOOL exitedEarly = NO;
		for (j=lastInserted; j<bSize; j++) {
			
			NoteCatalogEntry *catEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:j] pointerValue];
			int order = catEntry->nodeID - fileNodeIDOfNote(currentNote);
			
			if (order > 0) {    //if (A[i] < B[j])
				lastInserted = j;
				exitedEarly = YES;
				
				NSLog(@"File deleted as per CNID: %@", filenameOfNote(currentNote));
				[hfsRemovedEntries addObject:currentNote];
				
				break;
			} else if (order == 0) {			//if (A[i] == B[j])
				lastInserted = j + 1;
				exitedEarly = YES;
				
				
				//note was renamed!
				NSLog(@"File %@ renamed as per CNID to %@", filenameOfNote(currentNote), catEntry->filename);
				if (![self modifyNoteIfNecessary:currentNote usingCatalogEntry:catEntry]) {
					//at least update the file name, because we _know_ that changed
					
					directoryChangesFound = YES;
					
					[currentNote setFilename:(NSString*)catEntry->filename withExternalTrigger:YES];
				}
				
				notesChanged = YES;
				
				break;
			}
			
			//a new file was found on the disk! read it into memory!
			
			NSLog(@"File added as per CNID: %@", catEntry->filename);
			[hfsAddedEntries addObject:[NSValue valueWithPointer:catEntry]];
		}
		
		if (!exitedEarly) {
			
			NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:MIN(lastInserted, bSize-1)] pointerValue];
			if (fileNodeIDOfNote(currentNote) - appendedCatEntry->nodeID > 0) {
				lastInserted = bSize;
				
				//file deleted from disk; 
				NSLog(@"File deleted as per CNID: %@", filenameOfNote(currentNote));
				[hfsRemovedEntries addObject:currentNote];
			}
		}
    }
    
    for (j=lastInserted; j<bSize; j++) {
		NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:j] pointerValue];
		NSLog(@"File added as per CNID: %@", appendedCatEntry->filename);
		[hfsAddedEntries addObject:[NSValue valueWithPointer:appendedCatEntry]];
    }
	
	if ([hfsAddedEntries count] && [hfsRemovedEntries count]) {
		[self processNotesAddedByContent:hfsAddedEntries removed:hfsRemovedEntries];
	} else {
		//NSLog(@"hfsAddedEntries: %@, hfsRemovedEntries: %@", hfsAddedEntries, hfsRemovedEntries);
		if (![hfsRemovedEntries count]) {
			for (i=0; i<[hfsAddedEntries count]; i++) {
				NSLog(@"File _actually_ added: %@ (%s)", ((NoteCatalogEntry*)[[hfsAddedEntries objectAtIndex:i] pointerValue])->filename, _cmd);
				[self addNoteFromCatalogEntry:(NoteCatalogEntry*)[[hfsAddedEntries objectAtIndex:i] pointerValue]];
			}
		}
		
		if (![hfsAddedEntries count]) {
			[deletionManager addDeletedNotes:hfsRemovedEntries];
		}
	}
	
}

//reconcile the "actually" added/deleted files into renames for files with identical content, looking at logical size first
- (void)processNotesAddedByContent:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	//more than 1 entry in the same list could have the same file size, so sort-algo assumptions above don't apply here
	//instead of sorting, build a dict keyed by file size, with duplicate sizes (on the same side) chained into arrays
	//make temporary notes out of the new NoteCatalogEntries to allow their contents to be compared directly where sizes match
	
	NSUInteger i;
	NSMutableDictionary *addedDict = [NSMutableDictionary dictionaryWithCapacity:[addedEntries count]];
	
	for (i=0; i<[addedEntries count]; i++) {
		NSNumber *sizeKey = [NSNumber numberWithUnsignedInt:((NoteCatalogEntry*)[[addedEntries objectAtIndex:i] pointerValue])->logicalSize];
		id sameSizeObj = [addedDict objectForKey:sizeKey];
		
		if ([sameSizeObj isKindOfClass:[NSArray class]]) {
			//just insert it directly; an array already exists
			NSAssert([sameSizeObj isKindOfClass:[NSMutableArray class]], @"who's inserting immutable collections into my dictionary?");
			[sameSizeObj addObject:[addedEntries objectAtIndex:i]];
		} else if (sameSizeObj) {
			//two objects need to be inserted into the new array
			[addedDict setObject:[NSMutableArray arrayWithObjects:sameSizeObj, [addedEntries objectAtIndex:i], nil] forKey:sizeKey];
		} else {
			//nothing with this key, just insert it directly
			[addedDict setObject:[addedEntries objectAtIndex:i] forKey:sizeKey];
		}
	}
//	NSLog(@"removedEntries: %@", removedEntries);
//	NSLog(@"addedDict: %@", addedDict);
	
	for (i=0; i<[removedEntries count]; i++) {
		NoteObject *removedObj = [removedEntries objectAtIndex:i];
		NSNumber *sizeKey = [NSNumber numberWithUnsignedInt:fileSizeOfNote(removedObj)];
		BOOL foundMatchingContent = NO;
		
		//does any added item have the same size as removedObj?
		//if sizes match, see if that added item's actual content fully matches removedObj's
		//if content matches, then both items cancel each other out, with a rename operation resulting on the item in the removedEntries list
		//if content doesn't match, then check the next item in the array (if there is more than one matching size), and so on
		//any item in removedEntries that has no match in the addedEntries list is marked deleted
		//everything left over in the addedEntries list is marked as new
		
		id sameSizeObj = [addedDict objectForKey:sizeKey];
		NSUInteger addedObjCount = [sameSizeObj isKindOfClass:[NSArray class]] ? [sameSizeObj count]: 1;
		while (sameSizeObj && !foundMatchingContent && addedObjCount-- > 0) {
			NSValue *val = [sameSizeObj isKindOfClass:[NSArray class]] ? [sameSizeObj objectAtIndex:addedObjCount] : sameSizeObj;
			NoteObject *addedObjToCompare = [[NoteObject alloc] initWithCatalogEntry:[val pointerValue] delegate:self];
			
			if ([[addedObjToCompare contentString] isEqual:[removedObj contentString]]) {
				//process this pair as a modification
				
				NSLog(@"File %@ renamed as per content to %@", filenameOfNote(removedObj), filenameOfNote(addedObjToCompare));
				if (![self modifyNoteIfNecessary:removedObj usingCatalogEntry:[val pointerValue]]) {
					//at least update the file name, because we _know_ that changed
					directoryChangesFound = YES;
					notesChanged = YES;
					[removedObj setFilename:filenameOfNote(addedObjToCompare) withExternalTrigger:YES];
				}
				
				if ([sameSizeObj isKindOfClass:[NSArray class]]) {
					[sameSizeObj removeObjectIdenticalTo:val];
				} else {
					[addedDict removeObjectForKey:sizeKey];
				}
				//also remove it from original array, which is easier to process for the leftovers that will actually be added
				[addedEntries removeObjectIdenticalTo:val];
				foundMatchingContent = YES;
			}
			[addedObjToCompare release];
		}
		
		if (!foundMatchingContent) {
			NSLog(@"File %@ _actually_ removed", filenameOfNote(removedObj));
			[deletionManager addDeletedNote:removedObj];
		}
	}
	
	for (i=0; i<[addedEntries count]; i++) {
		NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:i] pointerValue];
		NSLog(@"File _actually_ added: %@ (%s)", appendedCatEntry->filename, _cmd);
		[self addNoteFromCatalogEntry:appendedCatEntry];
    }	
}

@end


