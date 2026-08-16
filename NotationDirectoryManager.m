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
#import "NotationPrefs.h"
#import "NVRootedDirectory_Private.h"
#import "BufferUtils.h"
#import "GlobalPrefs.h"
#import "NotationSyncServiceManager.h"
#import "NoteObject.h"
#import "DeletionManager.h"
#import "NSCollection_utils.h"
#import "NSString_NV.h"

@interface NoteObject (NVDirectoryPreparation)
- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry snapshot:(NVFileSnapshot*)snapshot
	format:(int)format fallbackLabels:(NSString*)fallbackLabels
	fallbackEncoding:(NSStringEncoding)fallbackEncoding
	fallbackCreatedDate:(CFAbsoluteTime)fallbackCreatedDate error:(NSError**)error;
@end

static void NVRecordUniqueObject(NSMutableDictionary *objects, id key, id object) {
	[objects setObject:[objects objectForKey:key] ? (id)[NSNull null] : object forKey:key];
}

/*
 * One scan owns one of these private staging objects. Containers intentionally
 * hold ordinary NoteObjects instead of introducing a second model hierarchy:
 * detached notes are complete replacement values, while live notes are only
 * keys until commit. Nothing in this object is serialized or survives a retry.
 */
@interface NVDirectoryTransaction : NSObject {
@public
	NSMapTable *updates;
	NSMutableArray *additions;
	NSMutableArray *deletions;
	NSMutableSet *verifiedNotes;
	NSMutableArray *identityUpdates;
	NSMutableArray *changedNotes;
	NSMutableDictionary *preparedCandidates;
	NSMutableSet *candidatesWithoutTags;
	NSString *volumeUUID;
	BOOL hasChanges;
}
@end

@implementation NVDirectoryTransaction
- (id)init {
	self = [super init];
	if (self) {
		updates = [[NSMapTable strongToStrongObjectsMapTable] retain];
		additions = [[NSMutableArray alloc] init];
		deletions = [[NSMutableArray alloc] init];
		verifiedNotes = [[NSMutableSet alloc] init];
		identityUpdates = [[NSMutableArray alloc] init];
		changedNotes = [[NSMutableArray alloc] init];
		preparedCandidates = [[NSMutableDictionary alloc] init];
		candidatesWithoutTags = [[NSMutableSet alloc] init];
	}
	return self;
}
- (void)dealloc {
	[updates release];
	[additions release];
	[deletions release];
	[verifiedNotes release];
	[identityUpdates release];
	[changedNotes release];
	[preparedCandidates release];
	[candidatesWithoutTags release];
	[volumeUUID release];
	[super dealloc];
}
@end

@implementation NotationController (NotationDirectoryManager)

#define sortedCatalogEntries ([(NVRootedDirectoryCatalog*)directoryCatalog sortedEntries])
#define catEntriesCount ([(NVRootedDirectoryCatalog*)directoryCatalog count])

- (void)initializeFileMetadataVolumeUUID {
	if (currentFileMetadataVolumeUUID || [self currentNoteStorageFormat] == SingleDatabaseFormat) return;
	currentFileMetadataVolumeUUID = [[[self noteDirectory] volumeUUIDString] copy];
}

- (BOOL)archivedFileMetadataIsForCurrentVolume {
	return currentFileMetadataVolumeUUID &&
		[currentFileMetadataVolumeUUID isEqualToString:[notationPrefs fileMetadataVolumeUUID]];
}

//whenever a note uses this method to change its filename, we will have to re-establish all the links to it
- (NSString*)uniqueFilenameForTitle:(NSString*)title fromNote:(NoteObject*)note {
	BOOL isUnique = YES;
	NSString *uniqueFilename = title;
	NSMutableString *sanitizedName = [[uniqueFilename mutableCopy] autorelease];
	[sanitizedName replaceOccurrencesOfString:@"/" withString:@":" options:0
		range:NSMakeRange(0, [sanitizedName length])];
	if ([sanitizedName length] && [sanitizedName characterAtIndex:0] == (unichar)'.')
		[sanitizedName replaceCharactersInRange:NSMakeRange(0, 1) withString:@"_"];
	uniqueFilename = [[sanitizedName copy] autorelease];

	int noteFormat = [notationPrefs notesStorageFormat] || !note ? [notationPrefs notesStorageFormat] : storageFormatOfNote(note);
	NSString *extension = [notationPrefs chosenPathExtensionForFormat:noteFormat];
	if (note && filenameOfNote(note) && [notationPrefs pathExtensionAllowed:[filenameOfNote(note) pathExtension] forFormat:noteFormat])
		extension = [filenameOfNote(note) pathExtension];
	uniqueFilename = [uniqueFilename filenameExpectingAdditionalCharCount:(int)(3 + [extension length] + 2)];

	unsigned int iteration = 0;
	do {
		isUnique = YES;
		for (NoteObject *aNote in allNotes) {
			NSString *basefilename = [filenameOfNote(aNote) stringByDeletingPathExtension];
			if (note != aNote && [basefilename caseInsensitiveCompare:uniqueFilename] == NSOrderedSame) {
				isUnique = NO;
				uniqueFilename = [uniqueFilename stringByDeletingPathExtension];
				uniqueFilename = [uniqueFilename stringByAppendingPathExtension:[@((int)++iteration) stringValue]];
				break;
			}
		}
		NSString *candidate = [uniqueFilename stringByAppendingPathExtension:extension];
		BOOL databaseDestinationExists = note && storageFormatOfNote(note) == SingleDatabaseFormat &&
			[[self noteDirectory] regularFileExistsNamed:candidate];
		if (isUnique && !databaseDestinationExists &&
			(!note || ![candidate isEqualToString:filenameOfNote(note)]) &&
			[[self noteDirectory] caseInsensitiveRegularFileExistsNamed:candidate
				excludingName:(note ? filenameOfNote(note) : nil)]) {
			isUnique = NO;
			uniqueFilename = [uniqueFilename stringByDeletingPathExtension];
			uniqueFilename = [uniqueFilename stringByAppendingPathExtension:[@((int)++iteration) stringValue]];
		}
	} while (!isUnique);
	return [uniqueFilename stringByAppendingPathExtension:extension];
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
		[lcNamesDict setObject:path forKey:[[[path lastPathComponent]
			precomposedStringWithCanonicalMapping] lowercaseString]];
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
	/*
	 * FSEvents is only a prompt to rescan; its paths and event ordering are not
	 * used as authoritative state. Delivery on the main queue serializes this
	 * callback with reconciliation and note writes, and the scheduled-scan bit
	 * coalesces a burst of events into one later FD-based transaction.
	 *
	 * WatchRoot reports the original watched path after that path or an ancestor
	 * moves.  The bookmark/file reference still follows the directory, but the
	 * path-based FSEvents stream does not, so rebuild it after this callback has
	 * returned.  RootChanged event IDs are documented to be zero; retaining that
	 * check keeps ordinary events from accidentally reconfiguring the stream.
	 */
	NotationController* self = (NotationController*)info;
	
	BOOL rootChanged = NO, invalidated = NO;
	size_t i = 0;
	for (i = 0; i < num_events; i++) {
		if ((flags[i] & kFSEventStreamEventFlagRootChanged) && !event_ids[i]) {
			rootChanged = YES;
		}
		if (flags[i] & (kFSEventStreamEventFlagMustScanSubDirs |
			kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
			kFSEventStreamEventFlagEventIdsWrapped)) invalidated = YES;
	}
	[self _directoryEventOccurredWithRootChange:rootChanged invalidated:invalidated];
}

/*
 * The scheduler uses one run-loop timer for two independent obligations. A
 * successful scan must not cancel a pending write retry and vice versa. The
 * scheduled-scan bit also makes already-queued performSelector callbacks cheap
 * no-ops after a direct scan or stop, avoiding fragile selector cancellation.
 */
- (void)_cancelDirectoryRetry {
	directoryRetryPending = NO;
	if (!writeRetryPending) {
		if (directoryRetryTimer) {
			[directoryRetryTimer invalidate];
			self.directoryRetryTimer = nil;
		}
		directoryRetryAttempt = 0;
	}
}

- (void)_requestDirectoryScan {
	if (directoryScanScheduled) return;
	directoryScanScheduled = YES;
	[self performSelector:@selector(_performScheduledDirectoryScan) withObject:nil afterDelay:0.0];
}

- (void)_performScheduledDirectoryScan {
	if (!directoryScanScheduled) return;
	directoryScanScheduled = NO;
	if (directoryStreamNeedsReconfiguration) {
		if ([self _configureDirEventStream]) directoryStreamNeedsReconfiguration = NO;
		else [self _scheduleDirectoryRetry];
	}
	[self synchronizeNotesFromDirectory];
}

- (void)_directoryEventOccurredWithRootChange:(BOOL)rootChanged invalidated:(BOOL)invalidated {
	NSAssert([NSThread isMainThread], @"directory events must be handled on main");
	if (rootChanged) {
		NSLog(@"FSEventsCallback detected directory dislocation; reconfiguring stream");
		directoryStreamNeedsReconfiguration = YES;
	}
	if (invalidated) directoryStreamNeedsReconfiguration = YES;
	directoryRetryPending = NO;
	if (directoryRetryTimer) {
		[directoryRetryTimer invalidate];
		self.directoryRetryTimer = nil;
	}
	directoryRetryAttempt = 0;
	if (writeRetryPending) [self _scheduleFilesystemRetryTimer];
	[self _requestDirectoryScan];
}

- (void)_retryDirectoryScan:(NSTimer*)timer {
	if (timer != directoryRetryTimer) return;
	BOOL retryDirectory = directoryRetryPending;
	BOOL retryWrites = writeRetryPending;
	directoryRetryPending = writeRetryPending = NO;
	self.directoryRetryTimer = nil;
	if (retryDirectory) [self _requestDirectoryScan];
	if (retryWrites) [self flushAllNoteChanges];
}

- (void)_scheduleFilesystemRetryTimer {
	if (directoryRetryTimer) return;
	static const NSTimeInterval delays[] = { 0.1, 0.5, 2.0, 10.0, 30.0 };
	NSUInteger index = MIN(directoryRetryAttempt, sizeof(delays) / sizeof(delays[0]) - 1);
	directoryRetryAttempt++;
	self.directoryRetryTimer = [NSTimer timerWithTimeInterval:delays[index] target:self
		selector:@selector(_retryDirectoryScan:) userInfo:nil repeats:NO];

	[[NSRunLoop mainRunLoop] addTimer:directoryRetryTimer forMode:NSRunLoopCommonModes];
}

- (void)_scheduleDirectoryRetry {
	directoryRetryPending = YES;
	[self _scheduleFilesystemRetryTimer];
}


- (BOOL)_configureDirEventStream {
	/*
	 * FSEvents requires a path even though note I/O must remain path-independent.
	 * Resolve the bookmark only to supply that transient subscription path; the
	 * scan and every later file operation continue through the rooted directory capability.
	 * Recreating instead of retargeting is required because FSEventStream has no
	 * API for changing its watched roots.
	 */
	
	if (!eventStreamStarted) return NO;
	
	if (noteDirEventStreamRef) {
		//remove the event stream if it already exists, so that a new one can be created
		[self _destroyDirEventStream];
	}
	
	NSString *path = [[self noteDirectory] transientPathForEventWatch:NULL];
	if (!path) {
		NSLog(@"Could not resolve notes directory for FSEvents");
		return NO;
	}
	
	FSEventStreamContext context = { 0, self, CFRetain, CFRelease, CFCopyDescription };
	
	noteDirEventStreamRef = FSEventStreamCreate(NULL, &FSEventsCallback, &context, (CFArrayRef)@[ path ], kFSEventStreamEventIdSinceNow,
												1.0, kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf);
	if (!noteDirEventStreamRef) {
		NSLog(@"could not create the FSEvents stream!");
		return NO;
	}
	/* IgnoreSelf avoids a redundant rescan after our own note installation. This
	 * is valid only while note writes and directory scans remain main-thread
	 * serialized; background writers must remove or replace this assumption. */
	FSEventStreamSetDispatchQueue(noteDirEventStreamRef, dispatch_get_main_queue());
	if (!FSEventStreamStart(noteDirEventStreamRef)) {
		NSLog(@"could not start the FSEvents stream!");
		FSEventStreamInvalidate(noteDirEventStreamRef);
		FSEventStreamRelease(noteDirEventStreamRef);
		noteDirEventStreamRef = NULL;
		return NO;
	}
	return YES;
}

- (void)_destroyDirEventStream {
	if (noteDirEventStreamRef) {
		FSEventStreamStop(noteDirEventStreamRef);
		FSEventStreamInvalidate(noteDirEventStreamRef);
		FSEventStreamRelease(noteDirEventStreamRef);
		noteDirEventStreamRef = NULL;
	}
}

- (void)startFileNotifications {
	eventStreamStarted = YES;
	directoryStreamNeedsReconfiguration = ![self _configureDirEventStream];
	if (directoryStreamNeedsReconfiguration) [self _scheduleDirectoryRetry];
}

- (void)stopFileNotifications {
	eventStreamStarted = NO;
	[self _destroyDirEventStream];
	[self _cancelDirectoryRetry];
	directoryScanScheduled = NO;
	directoryStreamNeedsReconfiguration = NO;
}

/* Read/decode helpers only produce detached values or copied identity records.
 * The unusual NSData copy in _stageIdentityForNote is required because the hot
 * catalog buffer is deliberately reused by the fence enumeration. */
- (NoteObject*)_preparedNoteForCatalogEntry:(NoteCatalogEntry*)entry
	fallbackNote:(NoteObject*)fallbackNote error:(NSError**)error {
	NVFileSnapshot *snapshot = [[self noteDirectory]
		snapshotForFileNamed:(NSString*)entry->filename error:error];
	if (!snapshot)
		return nil;
	NSString *fallbackLabels = fallbackNote ? labelsOfNote(fallbackNote) : @"";
	NSStringEncoding fallbackEncoding = fallbackNote ? fileEncodingOfNote(fallbackNote) : NSUTF8StringEncoding;
	CFAbsoluteTime fallbackCreatedDate = fallbackNote ? createdDateOfNote(fallbackNote) : 0.0;
	return [[[NoteObject alloc] initWithCatalogEntry:entry snapshot:snapshot
		format:[self currentNoteStorageFormat] fallbackLabels:fallbackLabels
		fallbackEncoding:fallbackEncoding fallbackCreatedDate:fallbackCreatedDate error:error] autorelease];
}

- (void)_stageIdentityForNote:(NoteObject*)note catalogEntry:(NoteCatalogEntry*)entry {
	NSString *newFilename = (NSString*)entry->filename;
	BOOL renamed = ![newFilename isEqualToString:filenameOfNote(note)];
	BOOL metadataChanged = !fileMetadataIsValidForNote(note) ||
		NVCompareTimespecs(fileAttributeChangeTimeOfNote(note),
			entry->attributeChangeTime) != NSOrderedSame ||
		documentIDOfNote(note) != entry->documentID || sessionFileIDOfNote(note) != entry->fileID;
	metadataChanged = metadataChanged ||
		sessionFileGenerationOfNote(note) != entry->generationCount;
	if (!renamed && !metadataChanged) return;
	NSData *entryData = [NSData dataWithBytes:entry length:sizeof(*entry)];
	[directoryTransaction->identityUpdates addObject:@[ note, newFilename,
		[newFilename stringByDeletingPathExtension], entryData, @(renamed) ]];
	directoryTransaction->hasChanges = YES;
	if (renamed && ![directoryTransaction->changedNotes containsObject:note])
		[directoryTransaction->changedNotes addObject:note];
}

- (NoteObject*)prepareNoteAdditionFromCatalogEntry:(NoteCatalogEntry*)entry error:(NSError**)error {
	NSAssert(directoryTransaction != nil, @"note additions must be prepared inside a directory transaction");
	NSString *filename = (NSString*)entry->filename;
	NoteObject *note = [directoryTransaction->preparedCandidates objectForKey:filename];
	if (!note) note = [self _preparedNoteForCatalogEntry:entry fallbackNote:nil error:error];
	if (!note) return nil;
	if (![directoryTransaction->additions containsObject:note])
		[directoryTransaction->additions addObject:note];
	directoryTransaction->hasChanges = YES;
	return note;
}

- (void)_stageOrAddDeletedNotes:(NSArray*)notes {
	for (NoteObject *note in notes)
		/* A missing file is not an external deletion while the live model still
		 * owes that file to disk (notably after replaying a WAL-only note). */
		if (![pendingFileWrites containsObject:note] &&
			![directoryTransaction->deletions containsObject:note])
			[directoryTransaction->deletions addObject:note];
}

/* All failable filesystem and decoding work has finished. Disconnect labels
 * first, apply the complete model change, reconnect once, then publish outward
 * effects so observers can never see a half-reconciled directory. */
- (void)_commitDirectoryTransaction:(NVDirectoryTransaction*)transaction {
	NSArray *updatedNotes = [[transaction->updates keyEnumerator] allObjects];
	for (NoteObject *note in updatedNotes) [note disconnectLabels];
	for (NoteObject *note in updatedNotes)
		[note applyPreparedFileStateFromNote:[transaction->updates objectForKey:note]];
	for (NSArray *identity in transaction->identityUpdates) {
		NoteCatalogEntry entry;
		[[identity objectAtIndex:3] getBytes:&entry length:sizeof(entry)];
		entry.filename = (CFStringRef)[identity objectAtIndex:1];
		[[identity objectAtIndex:0] applyCatalogEntry:&entry filename:[identity objectAtIndex:1]
			title:[identity objectAtIndex:2]];
	}
	for (NoteObject *note in updatedNotes) [note attachToDelegate:self];
	for (NoteObject *note in transaction->additions) [self _addNote:note];

	if (transaction->hasChanges) {
		notesChanged = YES;
		[self updateTitlePrefixConnections];
		[self resortAllNotes];
		[self refilterNotes];
	}
	[deletionManager reconcileVerifiedExistingNotes:transaction->verifiedNotes
		deletedNotes:transaction->deletions];
	for (NoteObject *note in transaction->changedNotes) {
		[note updateTablePreviewString];
		[note registerModificationWithOwnedServices];
		[self schedulePushToAllSyncServicesForNote:note];
		[self note:note attributeChanged:NotePreviewString];
		[delegate contentsUpdatedForNote:note];
	}
	for (NoteObject *note in transaction->additions)
		[self schedulePushToAllSyncServicesForNote:note];
	if ([transaction->changedNotes count])
		[self performSelector:@selector(scheduleUpdateListForAttribute:)
			withObject:NoteDateModifiedColumnString afterDelay:0.0];
	if (transaction->volumeUUID)
		[notationPrefs setFileMetadataVolumeUUID:transaction->volumeUUID];
}

- (BOOL)synchronizeNotesFromDirectory {
	/*
	 * Theory of operation:
	 *   1. Enumerate and prepare detached note values without touching live state.
	 *   2. Enumerate again and compare the exact names and reconciliation metadata.
	 *   3. Commit the prepared values only when both catalogs are identical.
	 *
	 * The exact second pass is the transaction fence. FSEvents is deliberately not
	 * part of that proof: delivery may lag filesystem mutation, and its main-queue
	 * callback cannot run during this synchronous scan. An event observed afterward
	 * simply schedules another complete transaction. A mutation after the second
	 * enumeration can therefore commit briefly stale but internally coherent state;
	 * its event provides eventual convergence without mixing two filesystem views.
	 *
	 * Single-database storage has no independently editable note files, so a
	 * directory scan would only rediscover the database and journal artifacts.
	 */
	NSAssert([NSThread isMainThread], @"directory reconciliation must run on main");
	directoryScanScheduled = NO;
	if ([self currentNoteStorageFormat] == SingleDatabaseFormat) return NO;
	if (directoryScanRunning) {
		[self _requestDirectoryScan];
		return NO;
	}
	directoryScanRunning = YES;
	[self initializeFileMetadataVolumeUUID];
	BOOL succeeded = NO, retry = YES;
	NVDirectoryTransaction *transaction = [[NVDirectoryTransaction alloc] init];
	NVRootedDirectoryCatalog *firstCatalog = nil;
	directoryTransaction = transaction;
	if (![self _readFilesInDirectory]) goto finished;
	if ([self _catalogContainsCaseInsensitiveCollision]) { retry = NO; goto finished; }
	transaction->volumeUUID = [currentFileMetadataVolumeUUID copy];
	firstCatalog = [directoryCatalog retain];

	if (catEntriesCount && [allNotes count]) {
		if (![self makeNotesMatchCatalogEntries:sortedCatalogEntries ofSize:catEntriesCount]) goto finished;
	} else if (![allNotes count]) {
		for (size_t index = 0; index < catEntriesCount; index++) {
			if (![notationPrefs catalogEntryAllowed:sortedCatalogEntries[index]]) continue;
			NSError *error = nil;
			if (![self prepareNoteAdditionFromCatalogEntry:sortedCatalogEntries[index] error:&error]) {
				NSLog(@"Could not prepare note '%@': %@", sortedCatalogEntries[index]->filename, error);
				goto finished;
			}
		}
	} else if (!catEntriesCount) {
		[self _stageOrAddDeletedNotes:allNotes];
	}

	/* _readFilesInDirectory replaces the controller's reusable hot buffers only
	 * after every prepared value has copied the catalog fields it needs. */
	if (![self _readFilesInDirectory]) goto finished;
	if ([self _catalogContainsCaseInsensitiveCollision]) { retry = NO; goto finished; }
	if (![firstCatalog isExactlyEqualToCatalog:directoryCatalog])
		goto finished;

	directoryTransaction = nil;
	[self _commitDirectoryTransaction:transaction];
	succeeded = YES;

finished:
	[firstCatalog release];
	directoryTransaction = nil;
	[transaction release];
	directoryScanRunning = NO;
	if (succeeded) {
		if (directoryStreamNeedsReconfiguration) {
			[self _scheduleDirectoryRetry];
		} else {
			directoryRetryPending = NO;
		}
		if (!directoryStreamNeedsReconfiguration && !writeRetryPending) {
			if (directoryRetryTimer) {
				[directoryRetryTimer invalidate];
				self.directoryRetryTimer = nil;
			}
			directoryRetryAttempt = 0;
		}
	} else if (retry) {
		[self _scheduleDirectoryRetry];
	}
	return succeeded;
}

- (BOOL)_catalogContainsCaseInsensitiveCollision {
	/*
	 * The note model deliberately treats filenames case-insensitively, even on a
	 * case-sensitive APFS volume.  Two catalog names that fold together cannot be
	 * reconciled deterministically.  Skipping the entire scan is safer than
	 * importing one and deleting or overwriting the other based on sort order.
	 * This sort also prepares sortedCatalogEntries for the name merge below.
	 */
	if (catEntriesCount < 2) return NO;
	[(NVRootedDirectoryCatalog*)directoryCatalog sortCaseInsensitively];
	for (size_t index = 1; index < catEntriesCount; index++) {
		if (CFStringCompare(sortedCatalogEntries[index - 1]->filename,
			sortedCatalogEntries[index]->filename, kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
			NSLog(@"Case-insensitive filename collision between '%@' and '%@'; directory synchronization skipped",
				sortedCatalogEntries[index - 1]->filename, sortedCatalogEntries[index]->filename);
			return YES;
		}
	}
	return NO;
}

//scour the notes directory for fresh meat
- (BOOL)_readFilesInDirectory {
	NSError *error = nil;
	NVRootedDirectoryCatalog *catalog = [[self noteDirectory] newCatalog:&error];
	if (!catalog) {
		[directoryCatalog release];
		directoryCatalog = nil;
		NSLog(@"Could not enumerate notes directory: %@", error);
		return NO;
	}
	[directoryCatalog release];
	directoryCatalog = catalog;
	return YES;
}

- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry {
	/*
	 * A catalog ctime mismatch means "some file state changed," not necessarily
	 * that the data fork changed.  Preserve the historical behavior of reloading
	 * content and tags together, but only after the cheap snapshot detects that
	 * mismatch.  If NV has unwritten edits, memory wins and the scheduled write
	 * will replace the external version; identity is still refreshed so a rename
	 * in that interval continues to follow the correct file.
	 * Pending notes retain their transient merge base; the shared atomic writer
	 * reads and merges this stable external version before replacement.
	 */
	struct timespec previousChangeTime = fileAttributeChangeTimeOfNote(aNoteObject);
	BOOL metadataChanged = !fileMetadataIsValidForNote(aNoteObject) ||
		NVCompareTimespecs(previousChangeTime,
			catEntry->attributeChangeTime) != NSOrderedSame ||
		(sessionFileIDOfNote(aNoteObject) && catEntry->fileID &&
			sessionFileIDOfNote(aNoteObject) != catEntry->fileID) ||
		(sessionFileGenerationOfNote(aNoteObject) && catEntry->generationCount &&
			sessionFileGenerationOfNote(aNoteObject) != catEntry->generationCount);
	NSAssert(directoryTransaction != nil, @"note reconciliation must be prepared inside a directory transaction");
	if (![directoryTransaction->verifiedNotes containsObject:aNoteObject])
		[directoryTransaction->verifiedNotes addObject:aNoteObject];
	NoteObject *candidate = [directoryTransaction->preparedCandidates
		objectForKey:(NSString*)catEntry->filename];
	if ((metadataChanged || candidate) && !aNoteObject->shouldWriteToFile) {
		NSError *error = nil;
		NSString *candidateName = (NSString*)catEntry->filename;
		NoteObject *prepared = candidate;
		if (!prepared)
			prepared = [self _preparedNoteForCatalogEntry:catEntry fallbackNote:aNoteObject error:&error];
		else if ([directoryTransaction->candidatesWithoutTags containsObject:candidateName])
			[prepared _setLabelString:labelsOfNote(aNoteObject)];
		if (!prepared) {
			NSLog(@"File %@ changed but could not be prepared: %@", catEntry->filename, error);
			return NO;
		}
		[directoryTransaction->updates setObject:prepared forKey:aNoteObject];
		if (![directoryTransaction->changedNotes containsObject:aNoteObject])
			[directoryTransaction->changedNotes addObject:aNoteObject];
		directoryTransaction->hasChanges = YES;
		return YES;
	}
	[self _stageIdentityForNote:aNoteObject catalogEntry:catEntry];
	return YES;
}

- (BOOL)_stageUnmatchedAddedEntries:(NSArray*)addedEntries removedNotes:(NSArray*)removedNotes {
	for (NSValue *value in addedEntries) {
		NoteCatalogEntry *entry = [value pointerValue];
		NSError *error = nil;
		if (![self prepareNoteAdditionFromCatalogEntry:entry error:&error]) {
			NSLog(@"Could not import note '%@': %@", entry->filename, error);
			return NO;
		}
	}
	[self _stageOrAddDeletedNotes:removedNotes];
	return YES;
}

- (BOOL)makeNotesMatchCatalogEntries:(NoteCatalogEntry**)catEntriesPtrs ofSize:(size_t)catCount {
	/*
	 * Both sides are sorted under the app's case-insensitive filename semantics,
	 * making the common unchanged case linear.  File-type/extension filtering is
	 * intentionally applied only to names that are genuinely new: an existing
	 * note may temporarily retain its old extension during lazy format conversion
	 * and must still be checked for edits.  Add/remove candidates are collected
	 * first because a rename appears as one of each in a directory snapshot.
	 */
    
    NSUInteger aSize = [allNotes count];
    size_t bSize = catCount;
    
    ResizeArray(&allNotesBuffer, (unsigned int)aSize, &allNotesBufferSize);
	
	NSAssert(allNotesBuffer != NULL, @"sorting buffer not initialized");
	
    NoteObject **currentNotes = allNotesBuffer;
    if (aSize > 0) {
        [allNotes getObjects:(id *)currentNotes range:NSMakeRange(0, aSize)];
    }
	
    mergesort((void *)allNotesBuffer, (size_t)aSize, sizeof(id), (int (*)(const void *, const void *))compareFilename);
    NSMutableArray *addedEntries = [NSMutableArray array];
    NSMutableArray *removedEntries = [NSMutableArray array];
	
	NSUInteger i = 0;
	size_t j = 0;
	while (i < aSize && j < bSize) {
		CFComparisonResult order = CFStringCompare(catEntriesPtrs[j]->filename,
			(CFStringRef)filenameOfNote(currentNotes[i]), kCFCompareCaseInsensitive);
		if (order == kCFCompareGreaterThan) {
			[removedEntries addObject:currentNotes[i++]];
		} else if (order == kCFCompareEqualTo) {
			if (![self modifyNoteIfNecessary:currentNotes[i++] usingCatalogEntry:catEntriesPtrs[j++]])
				return NO;
		} else {
			if ([notationPrefs catalogEntryAllowed:catEntriesPtrs[j]])
				[addedEntries addObject:[NSValue valueWithPointer:catEntriesPtrs[j]]];
			j++;
		}
	}
	while (i < aSize) [removedEntries addObject:currentNotes[i++]];
	while (j < bSize) {
		if ([notationPrefs catalogEntryAllowed:catEntriesPtrs[j]])
			[addedEntries addObject:[NSValue valueWithPointer:catEntriesPtrs[j]]];
		j++;
	}

	if ([addedEntries count] && [removedEntries count])
		return [self processNotesAddedByIdentity:addedEntries removed:removedEntries];
	return [self _stageUnmatchedAddedEntries:addedEntries removedNotes:removedEntries];
}

- (BOOL)_matchAddedEntries:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries
	usingDocumentIdentifiers:(BOOL)useDocumentIdentifiers {
	/*
	 * Filename reconciliation leaves two kinds of unmatched objects: catalog
	 * entries for names newly present on disk, and live notes whose old names have
	 * disappeared.  A rename therefore looks like one entry in each array.  This
	 * method tries to pair those entries by one filesystem identifier; successful
	 * pairs are removed so the next identity tier sees only unresolved candidates.
	 *
	 * NVRecordUniqueObject builds a reverse index for each side.  The first object
	 * seen for an identifier is stored directly; a second occurrence replaces it
	 * with NSNull.  Thus an object lookup proves that the identifier occurs exactly
	 * once on that side.  We pair only identifiers unique on both sides, because a
	 * duplicate cannot identify which file was renamed.  Zero means no identifier
	 * is available and is ignored.
	 *
	 * Persistent 32-bit document IDs are qualified by volume before this method is
	 * called.  The 64-bit file ID is deliberately session-only and never archived.
	 * Darwin's generation count changes on ordinary edits, so it is an invalidation
	 * token rather than an incarnation qualifier for rename matching.
	 */
	NSMutableDictionary *removedByIdentifier = [NSMutableDictionary dictionary];
	for (NoteObject *note in removedEntries) {
		uint64_t identifier = useDocumentIdentifiers ? documentIDOfNote(note) : sessionFileIDOfNote(note);
		if (!identifier) continue;
		NSNumber *key = @((unsigned long long)identifier);
		NVRecordUniqueObject(removedByIdentifier, key, note);
	}
	NSMutableDictionary *addedByIdentifier = [NSMutableDictionary dictionary];
	for (NSValue *value in addedEntries) {
		NoteCatalogEntry *entry = [value pointerValue];
		uint64_t identifier = useDocumentIdentifiers ? entry->documentID : entry->fileID;
		if (!identifier) continue;
		NSNumber *key = @((unsigned long long)identifier);
		NVRecordUniqueObject(addedByIdentifier, key, value);
	}
	NSUInteger index = 0;
	while (index < [addedEntries count]) {
		NSValue *value = [addedEntries objectAtIndex:index];
		NoteCatalogEntry *entry = [value pointerValue];
		uint64_t identifier = useDocumentIdentifiers ? entry->documentID : entry->fileID;
		NSNumber *key = @((unsigned long long)identifier);
		id note = identifier && [addedByIdentifier objectForKey:key] == value ?
			[removedByIdentifier objectForKey:key] : nil;
		if (!note || note == [NSNull null]) {
			index++;
			continue;
		}
		NSLog(@"File %@ renamed by %@ to %@", filenameOfNote(note),
			useDocumentIdentifiers ? @"document identifier" : @"session file identifier", entry->filename);
		if (![self modifyNoteIfNecessary:note usingCatalogEntry:entry]) return NO;
		[addedEntries removeObjectAtIndex:index];
		[removedEntries removeObjectIdenticalTo:note];
	}
	return YES;
}

- (BOOL)processNotesAddedByIdentity:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	/* Persistent document identity survives APFS moves and safe saves, but is only
	 * volume-local.  The inode-like session ID catches zero-document-ID renames;
	 * content is the portable last resort after both identity passes. */
	if ([self archivedFileMetadataIsForCurrentVolume])
		if (![self _matchAddedEntries:addedEntries removed:removedEntries usingDocumentIdentifiers:YES]) return NO;
	if ([addedEntries count] && [removedEntries count])
		if (![self _matchAddedEntries:addedEntries removed:removedEntries usingDocumentIdentifiers:NO]) return NO;
	if ([addedEntries count] && [removedEntries count]) {
		return [self processNotesAddedByContent:addedEntries removed:removedEntries];
	}
	return [self _stageUnmatchedAddedEntries:addedEntries removedNotes:removedEntries];
}

- (BOOL)processNotesAddedByContent:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	/*
	 * The identifier passes leave only files whose identity cannot be established
	 * from filesystem metadata.  Content is the portable identity of last resort:
	 * if one newly present file and one missing note have identical content, they
	 * can be treated as the two names of a rename.  Repeated content on either side
	 * is ambiguous, so NVRecordUniqueObject marks that dictionary entry with NSNull
	 * and the candidates remain an ordinary addition and removal.
	 *
	 * Every added file is read coherently and decoded into a detached NoteObject
	 * before either work list is changed.  This is an all-or-nothing preflight: an
	 * unreadable or invalid candidate aborts the scan instead of allowing an old
	 * note to be deleted and a blank replacement imported.  The detached values
	 * are cached in the transaction, including the distinction between absent and
	 * empty tags, so both rename staging and ordinary import reuse the same verified
	 * read.  The catalog fence later confirms that the directory did not change
	 * before the transaction commits.
	 *
	 * Finally, additions are visited in their original deterministic order.  A
	 * unique pair is staged as a rename and removed from both arrays; the common
	 * finalizer imports and deletes whatever remains.
	 *
	 * Rename candidate sets are normally tiny, so two dictionaries are
	 * simpler than restoring the old size-sorting/index machinery.
	 */
	NSMutableDictionary *addedByContent = [NSMutableDictionary dictionary];
	for (NSValue *value in addedEntries) {
		NoteCatalogEntry *entry = [value pointerValue];
		NSError *error = nil;
		NVFileSnapshot *snapshot = [[self noteDirectory]
			snapshotForFileNamed:(NSString*)entry->filename error:&error];
		if (!snapshot) {
			NSLog(@"Could not inspect rename candidate '%@': %@", entry->filename, error);
			return NO;
		}
		NoteObject *prepared = [[[NoteObject alloc] initWithCatalogEntry:entry snapshot:snapshot
			format:[self currentNoteStorageFormat] fallbackLabels:@""
			fallbackEncoding:NSUTF8StringEncoding fallbackCreatedDate:0.0 error:&error] autorelease];
		if (!prepared) {
			NSLog(@"Could not decode rename candidate '%@': %@", entry->filename, error);
			return NO;
		}
		[directoryTransaction->preparedCandidates setObject:prepared
			forKey:(NSString*)entry->filename];
		if (![snapshot tags])
			[directoryTransaction->candidatesWithoutTags addObject:(NSString*)entry->filename];
		NSString *content = [[prepared contentString] string];
		NVRecordUniqueObject(addedByContent, content, value);
	}

	NSMutableDictionary *removedByContent = [NSMutableDictionary dictionary];
	for (NoteObject *note in removedEntries) {
		NSString *content = [[note contentString] string];
		NVRecordUniqueObject(removedByContent, content, note);
	}

	NSUInteger index = 0;
	while (index < [addedEntries count]) {
		NSValue *value = [addedEntries objectAtIndex:index];
		NoteCatalogEntry *entry = [value pointerValue];
		NoteObject *prepared = [directoryTransaction->preparedCandidates
			objectForKey:(NSString*)entry->filename];
		NSString *content = [[prepared contentString] string];
		id note = [addedByContent objectForKey:content] == value ?
			[removedByContent objectForKey:content] : nil;
		if (!note || note == [NSNull null]) {
			index++;
			continue;
		}
		NSLog(@"File %@ renamed by unique content to %@", filenameOfNote(note), entry->filename);
		if (![self modifyNoteIfNecessary:note usingCatalogEntry:entry]) return NO;
		[addedEntries removeObjectAtIndex:index];
		[removedEntries removeObjectIdenticalTo:note];
	}

	return [self _stageUnmatchedAddedEntries:addedEntries removedNotes:removedEntries];
}

@end
