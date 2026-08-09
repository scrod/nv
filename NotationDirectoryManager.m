//
//  NotationDirectoryManager.m
//  Notation
//
//  Created by Zachary Schneirov on 12/10/09.

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

#import "NotationDirectoryManager.h"
#import "NSFileManager_NV.h"
#import "NotationPrefs.h"
#import "BufferUtils.h"
#import "GlobalPrefs.h"
#import "NotationSyncServiceManager.h"
#import "NoteObject.h"
#import "DeletionManager.h"
#import "NSCollection_utils.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

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
		[lcNamesDict setObject:path forKey:[[[[path lastPathComponent] precomposedStringWithCanonicalMapping] 
											 lowercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"/"]];
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


void FSEventsCallback(ConstFSEventStreamRef stream, void* info, size_t num_events, void* event_paths, 
					  const FSEventStreamEventFlags flags[],
                      const FSEventStreamEventId event_ids[]) {
	NotationController* self = (NotationController*)info;
	
	BOOL rootChanged = NO;
	size_t i = 0;
	for (i = 0; i < num_events; i++) {
		//on 10.5, could also check whether all the events are bookended by eventIDs that were contemporaneous with a change by NotationFileManager
		//as it lacks kFSEventStreamCreateFlagIgnoreSelf
		if ((flags[i] & kFSEventStreamEventFlagRootChanged) && !event_ids[i]) {
			rootChanged = YES;
			break;
		}
	}
	
	//the directory was moved; re-initialize the event stream for the new path
	//but do so after this callback ends to avoid confusing FSEvents
	if (rootChanged) {
		NSLog(@"FSEventsCallback detected directory dislocation; reconfiguring stream");
		[self performSelector:@selector(_configureDirEventStream) withObject:nil afterDelay:0];
	}
	
	//NSLog(@"FSEventsCallback got a path change");
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNotesFromDirectory) object:nil];
	[self performSelector:@selector(synchronizeNotesFromDirectory) withObject:nil afterDelay:0.0];
}


- (void)_configureDirEventStream {
	//"updates" the event stream to point to the current notation directory path
	//or if the stream doesn't exist, creates it
	
	if (!eventStreamStarted) return;
	
	if (noteDirEventStreamRef) {
		//remove the event stream if it already exists, so that a new one can be created
		[self _destroyDirEventStream];
	}
	
	NSURL *eventURL = [NSURL URLByResolvingBookmarkData:noteDirectoryBookmarkData
		options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];
	NSString *path = [eventURL path];
	if (!path) {
		NSLog(@"Could not resolve notes directory for FSEvents");
		return;
	}
	
	FSEventStreamContext context = { 0, self, CFRetain, CFRelease, CFCopyDescription };
	
	noteDirEventStreamRef = FSEventStreamCreate(NULL, &FSEventsCallback, &context, (CFArrayRef)[NSArray arrayWithObject:path], kFSEventStreamEventIdSinceNow, 
												1.0, kFSEventStreamCreateFlagWatchRoot | 0x00000008 /*kFSEventStreamCreateFlagIgnoreSelf*/);
	
	FSEventStreamScheduleWithRunLoop(noteDirEventStreamRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	if (!FSEventStreamStart(noteDirEventStreamRef)) {
		NSLog(@"could not start the FSEvents stream!");
	}
	
}

- (void)_destroyDirEventStream {
	if (eventStreamStarted) {
		NSAssert(noteDirEventStreamRef != NULL, @"can't destroy a NULL event stream");
		
		FSEventStreamStop(noteDirEventStreamRef);
		FSEventStreamInvalidate(noteDirEventStreamRef);
		FSEventStreamRelease(noteDirEventStreamRef);
		noteDirEventStreamRef = NULL;
	}
}

- (void)startFileNotifications {
	eventStreamStarted = YES;
	[self _configureDirEventStream];
}

- (void)stopFileNotifications {
	
	if (!eventStreamStarted) return;
	
	[self _destroyDirEventStream];
	
	eventStreamStarted = NO;
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
				[deletionManager addDeletedNotes:allNotes];
			}
		}
		
		if (directoryChangesFound) {
			[self resortAllNotes];
		    [self refilterNotes];
			
			[self updateTitlePrefixConnections];
		}
		
		//NSLog(@"file sync time: %g, ",[[NSDate date] timeIntervalSinceDate:date]);
		return YES;
    }
    
    return NO;
}

static UTCDateTime NVUTCDateTimeFromDirectoryTimespec(struct timespec value) {
	UTCDateTime date = { 0 };
	CFAbsoluteTime absoluteTime = (CFAbsoluteTime)value.tv_sec +
		((CFAbsoluteTime)value.tv_nsec / NSEC_PER_SEC) - kCFAbsoluteTimeIntervalSince1970;
	UCConvertCFAbsoluteTimeToUTCDateTime(absoluteTime, &date);
	return date;
}

static void NVCopyAttribute(const char **field, void *value, size_t size) {
	memcpy(value, *field, size);
	*field += size;
}

- (void)_resetCatalogEntries {
	for (size_t i = 0; i < catEntriesCount; i++) {
		if (catalogEntries[i].filename) {
			CFRelease(catalogEntries[i].filename);
			catalogEntries[i].filename = NULL;
		}
	}
	catEntriesCount = 0;
}

- (BOOL)_appendCatalogEntryNamed:(NSString*)filename finderInfo:(const uint8_t*)finderInfo
						logicalSize:(uint64_t)logicalSize fileID:(uint64_t)fileID
				 modificationTime:(struct timespec)modificationTime
			 attributeChangeTime:(struct timespec)changeTime {
	if (catEntriesCount == totalCatEntriesCount) {
		size_t oldCapacity = totalCatEntriesCount;
		size_t newCapacity = MAX((size_t)32, oldCapacity * 2);
		NoteCatalogEntry *newEntries = realloc(catalogEntries, newCapacity * sizeof(*catalogEntries));
		if (!newEntries) return NO;
		catalogEntries = newEntries;
		NoteCatalogEntry **newSortedEntries = realloc(sortedCatalogEntries,
			newCapacity * sizeof(*sortedCatalogEntries));
		if (!newSortedEntries) return NO;
		sortedCatalogEntries = newSortedEntries;
		bzero(catalogEntries + oldCapacity, (newCapacity - oldCapacity) * sizeof(*catalogEntries));
		totalCatEntriesCount = newCapacity;
	}

	NoteCatalogEntry *entry = &catalogEntries[catEntriesCount++];
	entry->filename = (CFMutableStringRef)[[filename precomposedStringWithCanonicalMapping] mutableCopy];
	entry->fileType = 0;
	if (finderInfo) memcpy(&entry->fileType, finderInfo, sizeof(entry->fileType));
	entry->logicalSize = (UInt32)(logicalSize & 0xFFFFFFFF);
	entry->nodeID = (UInt32)(fileID & 0xFFFFFFFF);
	entry->lastModified = NVUTCDateTimeFromDirectoryTimespec(modificationTime);
	entry->lastAttrModified = NVUTCDateTimeFromDirectoryTimespec(changeTime);
	return YES;
}

- (BOOL)_readFilesUsingDirectoryStream {
	int directoryFD = openat(noteDirectoryFileDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (directoryFD < 0) return NO;
	DIR *directory = fdopendir(directoryFD);
	if (!directory) {
		close(directoryFD);
		return NO;
	}

	BOOL succeeded = YES;
	struct dirent *item = NULL;
	for (;;) {
		errno = 0;
		item = readdir(directory);
		if (!item) {
			if (errno) succeeded = NO;
			break;
		}
		if (item->d_name[0] == '.' &&
			(item->d_name[1] == '\0' || (item->d_name[1] == '.' && item->d_name[2] == '\0')))
			continue;
		struct stat status;
		if (fstatat(directoryFD, item->d_name, &status, AT_SYMLINK_NOFOLLOW) < 0 ||
			!S_ISREG(status.st_mode))
			continue;

		NSString *filename = [[NSFileManager defaultManager]
			stringWithFileSystemRepresentation:item->d_name length:item->d_namlen];
		if (!filename) continue;
		struct attrlist requested;
		bzero(&requested, sizeof(requested));
		requested.bitmapcount = ATTR_BIT_MAP_COUNT;
		requested.commonattr = ATTR_CMN_FNDRINFO;
		struct {
			uint32_t length;
			uint8_t finderInfo[32];
		} attributes = { 0 };
		const uint8_t *finderInfo = getattrlistat(directoryFD, item->d_name, &requested,
			&attributes, sizeof(attributes), 0) == 0 ? attributes.finderInfo : NULL;
		if (![self _appendCatalogEntryNamed:filename finderInfo:finderInfo
			logicalSize:(uint64_t)status.st_size fileID:(uint64_t)status.st_ino
			modificationTime:status.st_mtimespec attributeChangeTime:status.st_ctimespec]) {
			succeeded = NO;
			break;
		}
	}
	closedir(directory);
	return succeeded;
}

//scour the notes directory for fresh meat
- (BOOL)_readFilesInDirectory {
	[self _resetCatalogEntries];

	int directoryFD = openat(noteDirectoryFileDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (directoryFD < 0) {
		NSLog(@"Could not open notes directory for enumeration: %s", strerror(errno));
		return NO;
	}

	struct attrlist requested;
	bzero(&requested, sizeof(requested));
	requested.bitmapcount = ATTR_BIT_MAP_COUNT;
	requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
		ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_FNDRINFO | ATTR_CMN_FILEID;
	requested.fileattr = ATTR_FILE_DATALENGTH;

	char buffer[64 * 1024];
	BOOL succeeded = YES;
	for (;;) {
		int count = getattrlistbulk(directoryFD, &requested, buffer, sizeof(buffer), 0);
		if (count < 0) {
			NSLog(@"Bulk directory enumeration unavailable (%s); using directory stream", strerror(errno));
			close(directoryFD);
			[self _resetCatalogEntries];
			succeeded = [self _readFilesUsingDirectoryStream];
			directoryFD = -1;
			break;
		}
		if (!count) break;

		const char *record = buffer;
		for (int index = 0; index < count; index++) {
			uint32_t recordLength = 0;
			NVCopyAttribute(&record, &recordLength, sizeof(recordLength));
			const char *nextRecord = record - sizeof(recordLength) + recordLength;
			attribute_set_t returned;
			NVCopyAttribute(&record, &returned, sizeof(returned));
			uint32_t entryError = 0;
			if (returned.commonattr & ATTR_CMN_ERROR)
				NVCopyAttribute(&record, &entryError, sizeof(entryError));

			attrreference_t nameReference = { 0 };
			const char *nameField = record;
			if (returned.commonattr & ATTR_CMN_NAME)
				NVCopyAttribute(&record, &nameReference, sizeof(nameReference));
			fsobj_type_t objectType = VNON;
			if (returned.commonattr & ATTR_CMN_OBJTYPE)
				NVCopyAttribute(&record, &objectType, sizeof(objectType));
			struct timespec modificationTime = { 0 };
			if (returned.commonattr & ATTR_CMN_MODTIME)
				NVCopyAttribute(&record, &modificationTime, sizeof(modificationTime));
			struct timespec changeTime = { 0 };
			if (returned.commonattr & ATTR_CMN_CHGTIME)
				NVCopyAttribute(&record, &changeTime, sizeof(changeTime));
			uint8_t finderInfo[32] = { 0 };
			if (returned.commonattr & ATTR_CMN_FNDRINFO)
				NVCopyAttribute(&record, finderInfo, sizeof(finderInfo));
			uint64_t fileID = 0;
			if (returned.commonattr & ATTR_CMN_FILEID)
				NVCopyAttribute(&record, &fileID, sizeof(fileID));
			off_t dataLength = 0;
			if (returned.fileattr & ATTR_FILE_DATALENGTH)
				NVCopyAttribute(&record, &dataLength, sizeof(dataLength));

			if (!entryError && objectType == VREG && nameReference.attr_length) {
				const char *name = nameField + nameReference.attr_dataoffset;
				NSString *filename = [NSString stringWithUTF8String:name];
				if (filename && ![self _appendCatalogEntryNamed:filename finderInfo:finderInfo
					logicalSize:(uint64_t)dataLength fileID:fileID modificationTime:modificationTime
					attributeChangeTime:changeTime]) {
					succeeded = NO;
					break;
				}
			}
			record = nextRecord;
		}
		if (!succeeded) break;
	}
	if (directoryFD >= 0) close(directoryFD);
	for (size_t i = 0; i < catEntriesCount; i++) sortedCatalogEntries[i] = &catalogEntries[i];
	return succeeded;
}

- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry {
	//check dates
	UTCDateTime lastReadDate = fileModifiedDateOfNote(aNoteObject);
	UTCDateTime *lastAttrModDate = attrsModifiedDateOfNote(aNoteObject);
	
	//should we always update the note's stored inode here regardless?
//	NSLog(@"content mod: %d,%d,%d, attr mod: %d,%d,%d", catEntry->lastModified.highSeconds,catEntry->lastModified.lowSeconds,catEntry->lastModified.fraction,
//		  catEntry->lastAttrModified.highSeconds,catEntry->lastAttrModified.lowSeconds,catEntry->lastAttrModified.fraction);
	
	updateForVerifiedExistingNote(deletionManager, aNoteObject);
	
	if (fileSizeOfNote(aNoteObject) != catEntry->logicalSize ||
		*(int64_t*)&lastReadDate != *(int64_t*)&(catEntry->lastModified) ||
		*(int64_t*)lastAttrModDate != *(int64_t*)&(catEntry->lastAttrModified)) {

		//assume the file on disk was modified by someone other than us
				
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
    
    NSUInteger aSize = [allNotes count];
    size_t bSize = catCount;
    
    ResizeArray(&allNotesBuffer, (unsigned int)aSize, &allNotesBufferSize);
	
	NSAssert(allNotesBuffer != NULL, @"sorting buffer not initialized");
	
    NoteObject **currentNotes = allNotesBuffer;
    if (aSize > 0) {
        [allNotes getObjects:(id *)currentNotes range:NSMakeRange(0, aSize)];
    }
	
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
                lastInserted = (unsigned int)bSize;
				
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
    NSUInteger aSize = [removedEntries count], bSize = [addedEntries count];
    
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
                lastInserted = (unsigned int)bSize;
				
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
				NSLog(@"File _actually_ added: %@ (%@)", ((NoteCatalogEntry*)[[hfsAddedEntries objectAtIndex:i] pointerValue])->filename, NSStringFromSelector(_cmd));
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
			
			if ([[[addedObjToCompare contentString] string] isEqualToString:[[removedObj contentString] string]]) {
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
			NSLog(@"File %@ _actually_ removed (size: %u)", filenameOfNote(removedObj), (unsigned)fileSizeOfNote(removedObj));
			[deletionManager addDeletedNote:removedObj];
		}
	}
	
	for (i=0; i<[addedEntries count]; i++) {
		NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:i] pointerValue];
		NSLog(@"File _actually_ added: %@ (%@)", appendedCatEntry->filename, NSStringFromSelector(_cmd));
		[self addNoteFromCatalogEntry:appendedCatEntry];
    }	
}

@end
