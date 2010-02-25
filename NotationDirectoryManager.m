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
				[[DeletionManager sharedManager] addDeletedNotes:allNotes];
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
	
	if (lastReadDate.lowSeconds != fileModDate.lowSeconds ||
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
			[[DeletionManager sharedManager] addDeletedNotes:removedEntries];
		}
	}
	
}

//find renamed notes through unique file IDs
//TODO: reconcile the "actually" added/deleted files into renames for files with identical content (sort by size)
- (void)processNotesAddedByCNID:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	unsigned int aSize = [removedEntries count], bSize = [addedEntries count];
    
    //sort on nodeID here
	[addedEntries sortUnstableUsingFunction:compareCatalogValueNodeID];
	[removedEntries sortUnstableUsingFunction:compareNodeID];
	
//	NSMutableArray *hfsAddedEntries = [NSMutableArray array];
//	NSMutableArray *hfsRemovedEntries = [NSMutableArray array];
	
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
				//[hfsRemovedEntries addObject:currentNote];
				[[DeletionManager sharedManager] addDeletedNote:currentNote];
				
				break;
			} else if (order == 0) {			//if (A[i] == B[j])
				lastInserted = j + 1;
				exitedEarly = YES;
				
				
				//note was renamed!
				NSLog(@"File %@ was renamed to %@", filenameOfNote(currentNote), catEntry->filename);
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
			[self addNoteFromCatalogEntry:catEntry];
		}
		
		if (!exitedEarly) {
			
			NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:MIN(lastInserted, bSize-1)] pointerValue];
			if (fileNodeIDOfNote(currentNote) - appendedCatEntry->nodeID > 0) {
				lastInserted = bSize;
				
				//file deleted from disk; 
				NSLog(@"File deleted as per CNID: %@", filenameOfNote(currentNote));
				//[hfsRemovedEntries addObject:currentNote];
				[[DeletionManager sharedManager] addDeletedNote:currentNote];
			}
		}
    }
    
    for (j=lastInserted; j<bSize; j++) {
		NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:j] pointerValue];
		NSLog(@"File _actually_ added: %@", appendedCatEntry->filename);
		[self addNoteFromCatalogEntry:appendedCatEntry];
    }
}

#if 0
- (void)processNotesAddedByContent:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	unsigned int aSize = [removedEntries count], bSize = [addedEntries count];
    
    //sort on file size here
	[addedEntries sortUnstableUsingFunction:compareCatalogValueFileSize];
	[removedEntries sortUnstableUsingFunction:compareFileSize];
    
    unsigned int i, j, lastInserted = 0;
    
    for (i=0; i<aSize; i++) {
		NoteObject *currentNote = [removedEntries objectAtIndex:i];
		
		BOOL exitedEarly = NO;
		for (j=lastInserted; j<bSize; j++) {
			
			NoteCatalogEntry *catEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:j] pointerValue];
			int order = catEntry->logicalSize - fileSizeOfNote(currentNote);
			
			if (order > 0) {    //if (A[i] < B[j])
				lastInserted = j;
				exitedEarly = YES;
				
				NSLog(@"File _actually_ deleted: %@", filenameOfNote(currentNote));
				[[DeletionManager sharedManager] addDeletedNote:currentNote];
				
				break;
			} else if (order == 0) {			//if (A[i] == B[j])
				lastInserted = j + 1;
				exitedEarly = YES;
				
				
				//note was renamed!
				NSLog(@"File %@ was renamed to %@", filenameOfNote(currentNote), catEntry->filename);
				if (![self modifyNoteIfNecessary:currentNote usingCatalogEntry:catEntry]) {
					//at least update the file name, because we _know_ that changed
					
					directoryChangesFound = YES;
					
					[currentNote setFilename:(NSString*)catEntry->filename withExternalTrigger:YES];
				}
				
				notesChanged = YES;
				
				break;
			}
			
			//a new file was found on the disk! read it into memory!
			
			NSLog(@"File _actually_ added: %@", catEntry->filename);
			[self addNoteFromCatalogEntry:catEntry];
		}
		
		if (!exitedEarly) {
			
			NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:MIN(lastInserted, bSize-1)] pointerValue];
			if (fileSizeOfNote(currentNote) - appendedCatEntry->logicalSize > 0) {
				lastInserted = bSize;
				
				//file deleted from disk; 
				NSLog(@"File _actually_ deleted: %@", filenameOfNote(currentNote));
				[[DeletionManager sharedManager] addDeletedNote:currentNote];
			}
		}
    }
    
    for (j=lastInserted; j<bSize; j++) {
		NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:j] pointerValue];
		NSLog(@"File _actually_ added: %@", appendedCatEntry->filename);
		[self addNoteFromCatalogEntry:appendedCatEntry];
    }
}
#endif

@end


