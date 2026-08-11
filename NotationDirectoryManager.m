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
#import "NotationFileManager.h"
#import "BufferUtils.h"
#import "GlobalPrefs.h"
#import "NotationSyncServiceManager.h"
#import "NoteObject.h"
#import "DeletionManager.h"
#import "NSCollection_utils.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

@interface NoteObject (NVDirectoryPreparation)
- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry snapshot:(const NVNoteFileSnapshot*)snapshot
	format:(int)format fallbackLabels:(NSString*)fallbackLabels
	fallbackEncoding:(NSStringEncoding)fallbackEncoding
	fallbackCreatedDate:(CFAbsoluteTime)fallbackCreatedDate error:(NSError**)error;
@end

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
	NSData *catalogToken;
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
	[catalogToken release];
	[volumeUUID release];
	[super dealloc];
}
@end

@implementation NotationController (NotationDirectoryManager)


static NSInteger compareCatalogEntryName(const void *one, const void *two) {
    return (int)CFStringCompare((CFStringRef)((*(NoteCatalogEntry **)one)->filename), 
								(CFStringRef)((*(NoteCatalogEntry **)two)->filename), kCFCompareCaseInsensitive);
}

static NSData *NVCatalogToken(NoteCatalogEntry **entries, size_t count) {
	/* Exact bytes, not a hash: equality is the commit fence, so even a theoretical
	 * collision is unnecessary risk.  Entries are already normalized and sorted. */
	NSMutableData *token = [NSMutableData dataWithCapacity:count * 64];
	for (size_t index = 0; index < count; index++) {
		NoteCatalogEntry *entry = entries[index];
		const char *name = [(NSString*)entry->filename UTF8String];
		uint32_t nameLength = name ? (uint32_t)strlen(name) : 0;
		struct __attribute__((packed)) {
			uint32_t nameLength;
			int64_t changeSeconds;
			int64_t changeNanoseconds;
			uint64_t fileID;
			uint32_t documentID;
			uint32_t generationCount;
		} fixed = { nameLength, entry->attributeChangeTime.tv_sec,
			entry->attributeChangeTime.tv_nsec, entry->fileID, entry->documentID,
			entry->generationCount };
		[token appendBytes:&fixed length:sizeof(fixed)];
		if (nameLength) [token appendBytes:name length:nameLength];
	}
	return token;
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
			[directoryRetryTimer release];
			directoryRetryTimer = nil;
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
		[directoryRetryTimer release];
		directoryRetryTimer = nil;
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
	[directoryRetryTimer release];
	directoryRetryTimer = nil;
	if (retryDirectory) [self _requestDirectoryScan];
	if (retryWrites) [self flushAllNoteChanges];
}

- (void)_scheduleFilesystemRetryTimer {
	if (directoryRetryTimer) return;
	static const NSTimeInterval delays[] = { 0.1, 0.5, 2.0, 10.0, 30.0 };
	NSUInteger index = MIN(directoryRetryAttempt, sizeof(delays) / sizeof(delays[0]) - 1);
	directoryRetryAttempt++;
	directoryRetryTimer = [[NSTimer timerWithTimeInterval:delays[index] target:self
		selector:@selector(_retryDirectoryScan:) userInfo:nil repeats:NO] retain];
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
	 * scan and every later file operation continue through noteDirectoryFileDescriptor.
	 * Recreating instead of retargeting is required because FSEventStream has no
	 * API for changing its watched roots.
	 */
	
	if (!eventStreamStarted) return NO;
	
	if (noteDirEventStreamRef) {
		//remove the event stream if it already exists, so that a new one can be created
		[self _destroyDirEventStream];
	}
	
	NSURL *eventURL = [NSURL URLByResolvingBookmarkData:noteDirectoryBookmarkData
		options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];
	NSString *path = [eventURL path];
	if (!path) {
		NSLog(@"Could not resolve notes directory for FSEvents");
		return NO;
	}
	
	FSEventStreamContext context = { 0, self, CFRetain, CFRelease, CFCopyDescription };
	
	noteDirEventStreamRef = FSEventStreamCreate(NULL, &FSEventsCallback, &context, (CFArrayRef)[NSArray arrayWithObject:path], kFSEventStreamEventIdSinceNow, 
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
	NVNoteFileSnapshot snapshot;
	if (![self readNoteFileSnapshot:&snapshot forNoteNamed:(NSString*)entry->filename error:error])
		return nil;
	NSString *fallbackLabels = fallbackNote ? labelsOfNote(fallbackNote) : @"";
	NSStringEncoding fallbackEncoding = fallbackNote ? fileEncodingOfNote(fallbackNote) : NSUTF8StringEncoding;
	CFAbsoluteTime fallbackCreatedDate = fallbackNote ? createdDateOfNote(fallbackNote) : 0.0;
	return [[[NoteObject alloc] initWithCatalogEntry:entry snapshot:&snapshot
		format:[self currentNoteStorageFormat] fallbackLabels:fallbackLabels
		fallbackEncoding:fallbackEncoding fallbackCreatedDate:fallbackCreatedDate error:error] autorelease];
}

- (void)_stageIdentityForNote:(NoteObject*)note catalogEntry:(NoteCatalogEntry*)entry {
	NSString *newFilename = (NSString*)entry->filename;
	BOOL renamed = ![newFilename isEqualToString:filenameOfNote(note)];
	BOOL metadataChanged = !fileMetadataIsValidForNote(note) ||
		fileAttributeChangeTimeOfNote(note).tv_sec != entry->attributeChangeTime.tv_sec ||
		fileAttributeChangeTimeOfNote(note).tv_nsec != entry->attributeChangeTime.tv_nsec ||
		documentIDOfNote(note) != entry->documentID || sessionFileIDOfNote(note) != entry->fileID;
	metadataChanged = metadataChanged ||
		sessionFileGenerationOfNote(note) != entry->generationCount;
	if (!renamed && !metadataChanged) return;
	NSData *entryData = [NSData dataWithBytes:entry length:sizeof(*entry)];
	[directoryTransaction->identityUpdates addObject:@[ note, newFilename,
		[newFilename stringByDeletingPathExtension], entryData, [NSNumber numberWithBool:renamed] ]];
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
		if (![directoryTransaction->deletions containsObject:note])
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
	directoryTransaction = transaction;
	if (![self _readFilesInDirectory]) goto finished;
	if ([self _catalogContainsCaseInsensitiveCollision]) { retry = NO; goto finished; }
	transaction->catalogToken = [NVCatalogToken(sortedCatalogEntries, catEntriesCount) retain];
	transaction->volumeUUID = [currentFileMetadataVolumeUUID copy];

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
		[transaction->deletions addObjectsFromArray:allNotes];
	}

	/* _readFilesInDirectory replaces the controller's reusable hot buffers only
	 * after every prepared value has copied the catalog fields it needs. */
	if (![self _readFilesInDirectory]) goto finished;
	if ([self _catalogContainsCaseInsensitiveCollision]) { retry = NO; goto finished; }
	if (![transaction->catalogToken isEqualToData:NVCatalogToken(sortedCatalogEntries, catEntriesCount)])
		goto finished;

	directoryTransaction = nil;
	[self _commitDirectoryTransaction:transaction];
	succeeded = YES;

finished:
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
				[directoryRetryTimer release];
				directoryRetryTimer = nil;
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
	mergesort(sortedCatalogEntries, catEntriesCount, sizeof(*sortedCatalogEntries),
		(int (*)(const void *, const void *))compareCatalogEntryName);
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

- (void)_resetCatalogEntries {
	/* Each scan owns its CFString filenames.  Reset before enumerating so an
	 * empty or failed scan can never reuse the preceding scan's entries. */
	for (size_t i = 0; i < catEntriesCount; i++) {
		if (catalogEntries[i].filename) {
			CFRelease(catalogEntries[i].filename);
			catalogEntries[i].filename = NULL;
		}
	}
	catEntriesCount = 0;
}

static __attribute__((always_inline)) inline BOOL NVAppendCatalogEntry(
	NoteCatalogEntry **entries, NoteCatalogEntry ***sortedEntries, size_t *entryCount,
	size_t *entryCapacity, CFStringRef filename, struct timespec changeTime,
	uint32_t documentID, uint64_t fileID, uint32_t generationCount) {
	/*
	 * The hot enumerator stores plain C records and a parallel pointer array so
	 * sorting never moves or retains Objective-C objects.  `filename` ownership
	 * transfers on success and is released here on failure.  Geometric growth is
	 * uncommon after the first scan and avoids a realloc for every directory batch.
	 */
	if (*entryCount == *entryCapacity) {
		size_t oldCapacity = *entryCapacity;
		size_t newCapacity = MAX((size_t)32, oldCapacity * 2);
		NoteCatalogEntry **newSortedEntries = realloc(*sortedEntries,
			newCapacity * sizeof(**sortedEntries));
		if (!newSortedEntries) { CFRelease(filename); return NO; }
		*sortedEntries = newSortedEntries;
		NoteCatalogEntry *newEntries = realloc(*entries, newCapacity * sizeof(**entries));
		if (!newEntries) { CFRelease(filename); return NO; }
		*entries = newEntries;
		bzero(*entries + oldCapacity, (newCapacity - oldCapacity) * sizeof(**entries));
		*entryCapacity = newCapacity;
	}

	NoteCatalogEntry *entry = &(*entries)[(*entryCount)++];
	entry->filename = filename;
	entry->attributeChangeTime = changeTime;
	entry->documentID = documentID;
	entry->fileID = fileID;
	entry->generationCount = generationCount;
	return YES;
}

- (BOOL)_appendCatalogEntryFilename:(CFStringRef)filename
	attributeChangeTime:(struct timespec)changeTime documentID:(uint32_t)documentID
	fileID:(uint64_t)fileID generationCount:(uint32_t)generationCount {
	// Shared by the slow fallback and tests; the bulk hot loop calls the inline helper directly.
	return NVAppendCatalogEntry(&catalogEntries, &sortedCatalogEntries, &catEntriesCount,
		&totalCatEntriesCount, filename, changeTime, documentID, fileID, generationCount);
}

static BOOL NVErrorIsNoSuchFile(NSError *error) {
	return ([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == ENOENT) ||
		([[error domain] isEqualToString:NSCocoaErrorDomain] && [error code] == NSFileNoSuchFileError);
}

- (BOOL)_readFilesUsingFoundation {
	/*
	 * Compatibility fallback only.  Foundation supplies names and vnode type;
	 * exact ctime and both IDs still come from the root-relative metadata helper.
	 * NSDate cannot round-trip every timespec nanosecond, so using
	 * NSURLAttributeModificationDateKey here would make an unchanged file appear
	 * changed on every fallback scan.  These path URLs are transient enumeration
	 * products—NoteObject never stores them and later access remains FD-relative.
	 * Rebuilding one path URL up front is faster than asking Foundation to resolve
	 * a file-reference URL for every child; it never becomes an identity token.
	 * A child ENOENT restarts the complete enumeration once instead of being
	 * omitted, because omission is indistinguishable from a user deletion.
	 */
	NSArray *keys = [NSArray arrayWithObject:NSURLIsRegularFileKey];
	for (NSUInteger attempt = 0; attempt < 2; attempt++) {
		[self _resetCatalogEntries];
		NSURL *directoryURL = [NSURL fileURLWithPath:[noteDirectoryURL path] isDirectory:YES];
		NSError *error = nil;
		NSArray *URLs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directoryURL
			includingPropertiesForKeys:keys options:0 error:&error];
		if (!URLs) {
			if (NVErrorIsNoSuchFile(error) && !attempt) continue;
			NSLog(@"Foundation directory enumeration failed: %@", error);
			[self _resetCatalogEntries];
			return NO;
		}
		BOOL transientFailure = NO;
		for (NSURL *URL in URLs) {
			error = nil;
			NSDictionary *values = [URL resourceValuesForKeys:keys error:&error];
			if (!values) {
				if (NVErrorIsNoSuchFile(error)) { transientFailure = YES; break; }
				NSLog(@"Foundation metadata lookup failed: %@", error);
				[self _resetCatalogEntries];
				return NO;
			}
			if (![[values objectForKey:NSURLIsRegularFileKey] boolValue]) continue;
			NSString *name = [URL lastPathComponent];
			NVFileInfo info;
			error = nil;
			if (![self getFileInfo:&info forNoteNamed:name error:&error]) {
				if (NVErrorIsNoSuchFile(error)) { transientFailure = YES; break; }
				NSLog(@"Root-relative metadata lookup failed for '%@': %@", name, error);
				[self _resetCatalogEntries];
				return NO;
			}
			CFMutableStringRef filename = (CFMutableStringRef)[name mutableCopy];
			const char *UTF8Name = [name UTF8String];
			if (UTF8Name && ContainsHighAscii(UTF8Name, strlen(UTF8Name)))
				CFStringNormalize(filename, kCFStringNormalizationFormC);
			if (![self _appendCatalogEntryFilename:filename
				attributeChangeTime:info.attributeModificationTime
				documentID:info.documentID fileID:info.fileID
				generationCount:info.generationCount]) {
				[self _resetCatalogEntries];
				return NO;
			}
		}
		if (!transientFailure) return YES;
		if (attempt) break;
	}
	[self _resetCatalogEntries];
	return NO;
}

typedef struct __attribute__((packed, aligned(4))) {
	uint32_t length;
	attribute_set_t returned;
	uint32_t error;
	attrreference_t name;
	fsobj_type_t objectType;
	struct timespec changeTime;
	uint32_t generationCount;
	uint32_t documentID;
	uint64_t fileID;
} NVBulkCatalogRecord;

/*
 * Darwin bulk records are packed on four-byte boundaries, including the 64-bit
 * file ID.  FSOPT_PACK_INVAL_ATTRS reserves each requested slot even when an
 * optional value such as document ID is unavailable; returned.commonattr says
 * which slots are valid.  Keep the explicit offsets so an SDK ABI change fails
 * at compile time instead of silently assigning identity data to the wrong file.
 */
_Static_assert(offsetof(NVBulkCatalogRecord, returned) == 4, "returned attribute offset");
_Static_assert(offsetof(NVBulkCatalogRecord, error) == 24, "error attribute offset");
_Static_assert(offsetof(NVBulkCatalogRecord, name) == 28, "name attribute offset");
_Static_assert(offsetof(NVBulkCatalogRecord, objectType) == 36, "object type attribute offset");
_Static_assert(offsetof(NVBulkCatalogRecord, changeTime) == 40, "change time attribute offset");
_Static_assert(offsetof(NVBulkCatalogRecord, generationCount) == 56, "generation count attribute offset");
_Static_assert(offsetof(NVBulkCatalogRecord, documentID) == 60, "document ID attribute offset");
_Static_assert(offsetof(NVBulkCatalogRecord, fileID) == 64, "file ID attribute offset");

static __attribute__((always_inline)) inline NVBulkCatalogParseResult _NVParseBulkCatalogRecord(const void *bytes, size_t availableLength,
	size_t *parsedRecordLength, const char **name, size_t *nameLength, struct timespec *changeTime,
	uint32_t *documentID, uint64_t *fileID, uint32_t *generationCount) {
	/*
	 * Validate every variable-length boundary before returning pointers into the
	 * syscall buffer.  The name reference is relative to the attrreference field
	 * itself and includes its trailing NUL.  Missing mandatory attributes make
	 * the packed layout unusable and trigger the Foundation fallback.  A file
	 * that vanished during enumeration invalidates the whole snapshot: continuing
	 * would make an existing note look deleted.  Non-regular vnodes are safe to
	 * skip; other per-entry errors use the compatibility fallback.
	 */
	if (!bytes || availableLength < sizeof(uint32_t)) return NVBulkCatalogRecordMalformed;
	const NVBulkCatalogRecord *record = bytes;
	uint32_t length = 0;
	memcpy(&length, &record->length, sizeof(length));
	if (length < sizeof(*record) || length > availableLength) return NVBulkCatalogRecordMalformed;
	if (parsedRecordLength) *parsedRecordLength = length;
	if (!(record->returned.commonattr & ATTR_CMN_ERROR)) return NVBulkCatalogRecordUnsupported;
	uint32_t entryError = 0;
	memcpy(&entryError, &record->error, sizeof(entryError));
	if (entryError)
		return entryError == ENOENT ? NVBulkCatalogRecordTransient : NVBulkCatalogRecordUnsupported;
	const attrgroup_t mandatory = ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_CHGTIME | ATTR_CMN_FILEID;
	if ((record->returned.commonattr & mandatory) != mandatory)
		return NVBulkCatalogRecordUnsupported;
	fsobj_type_t objectType = VNON;
	memcpy(&objectType, &record->objectType, sizeof(objectType));
	if (objectType != VREG) return NVBulkCatalogRecordSkipped;
	attrreference_t nameReference;
	memcpy(&nameReference, &record->name, sizeof(nameReference));
	if (nameReference.attr_length <= 1 || nameReference.attr_dataoffset < 0)
		return NVBulkCatalogRecordMalformed;
	size_t nameOffset = offsetof(NVBulkCatalogRecord, name) + (size_t)nameReference.attr_dataoffset;
	if (nameOffset < sizeof(*record) || nameOffset > length ||
		nameReference.attr_length > length - nameOffset)
		return NVBulkCatalogRecordMalformed;
	const char *recordName = (const char *)bytes + nameOffset;
	if (recordName[nameReference.attr_length - 1] != '\0') return NVBulkCatalogRecordMalformed;
	if (memchr(recordName, '\0', nameReference.attr_length - 1)) return NVBulkCatalogRecordMalformed;
	if (name) *name = recordName;
	if (nameLength) *nameLength = nameReference.attr_length - 1;
	if (changeTime) memcpy(changeTime, &record->changeTime, sizeof(*changeTime));
	if (fileID) memcpy(fileID, &record->fileID, sizeof(*fileID));
	if (generationCount) *generationCount =
		(record->returned.commonattr & ATTR_CMN_GEN_COUNT) ? record->generationCount : 0;
	if (documentID) *documentID = (record->returned.commonattr & ATTR_CMN_DOCUMENT_ID) ?
		record->documentID : 0;
	return NVBulkCatalogRecordFile;
}

NVBulkCatalogParseResult NVParseBulkCatalogRecord(const void *bytes, size_t availableLength,
	size_t *parsedRecordLength, const char **name, size_t *nameLength, struct timespec *changeTime,
	uint32_t *documentID, uint64_t *fileID, uint32_t *generationCount) {
	// Non-inlined seam for malformed-record and optional-document-ID regression tests.
	return _NVParseBulkCatalogRecord(bytes, availableLength, parsedRecordLength, name, nameLength,
		changeTime, documentID, fileID, generationCount);
}

- (int)_getattrlistbulk:(int)directoryFD attributes:(void*)attributes
	buffer:(void*)buffer size:(size_t)bufferSize options:(uint64_t)options {
	/*
	 * Keep the syscall behind one overridable message so the complete
	 * partial-results-to-Foundation transition can be regression tested.  This
	 * is once per 64 KiB batch, not once per entry, so dispatch cost is lost in
	 * syscall noise and the parser remains the measured hot loop.
	 */
	return getattrlistbulk(directoryFD, attributes, buffer, bufferSize, options);
}

//scour the notes directory for fresh meat
- (BOOL)_readFilesInDirectory {
	/*
	 * getattrlistbulk advances the directory position of the descriptor supplied
	 * to it.  Root-relative file operations do not consume that position, so
	 * rewind the long-lived root FD before each scan instead of reopening ".".
	 *
	 * The requested fields are intentionally only name, vnode type, ctime, and
	 * the two identity candidates.  ctime is a cheap invalidation token for both
	 * content and xattr changes.  Full mtime/creation/size metadata is fetched in
	 * from one root-relative file descriptor only after this pass identifies a
	 * changed, new, or content-fallback candidate.  The 64 KiB buffer and direct CFString
	 * construction are measured choices for this hot path; normalization is a
	 * no-op for ASCII, so only non-ASCII UTF-8 names pay for a mutable copy.
	 * ENOENT in a returned record invalidates the partial catalog and retries once;
	 * persistent churn aborts the scan without exposing partial state.
	 */
	struct attrlist requested;
	bzero(&requested, sizeof(requested));
	requested.bitmapcount = ATTR_BIT_MAP_COUNT;
	requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
		ATTR_CMN_OBJTYPE | ATTR_CMN_CHGTIME | ATTR_CMN_GEN_COUNT |
		ATTR_CMN_DOCUMENT_ID | ATTR_CMN_FILEID;

	char buffer[64 * 1024];
	for (NSUInteger attempt = 0; attempt < 2; attempt++) {
		[self _resetCatalogEntries];
		if (lseek(noteDirectoryFileDescriptor, 0, SEEK_SET) < 0) {
			NSLog(@"Could not rewind notes directory for enumeration: %s", strerror(errno));
			return NO;
		}

		BOOL succeeded = YES, transientFailure = NO, useFoundation = NO;
		for (;;) {
			int count = [self _getattrlistbulk:noteDirectoryFileDescriptor attributes:&requested
				buffer:buffer size:sizeof(buffer)
				options:FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS];
			if (count < 0) {
				NSLog(@"Bulk directory enumeration unavailable (%s); using Foundation", strerror(errno));
				useFoundation = YES;
				break;
			}
			if (!count) break;

			const char *recordBytes = buffer;
			for (int index = 0; index < count; index++) {
				size_t available = sizeof(buffer) - (size_t)(recordBytes - buffer);
				size_t recordLength = 0, nameLength = 0;
				const char *name = NULL;
				struct timespec changeTime = { 0 };
				uint32_t documentID = 0;
				uint32_t generationCount = 0;
				uint64_t fileID = 0;
				NVBulkCatalogParseResult result = _NVParseBulkCatalogRecord(recordBytes, available,
					&recordLength, &name, &nameLength, &changeTime, &documentID, &fileID,
					&generationCount);
				if (result == NVBulkCatalogRecordTransient) {
					transientFailure = YES;
					succeeded = NO;
					break;
				}
				if (result < NVBulkCatalogRecordSkipped) {
					succeeded = NO;
					break;
				}
				if (result == NVBulkCatalogRecordFile) {
					CFStringRef filename = CFStringCreateWithBytes(kCFAllocatorDefault,
						(const UInt8 *)name, nameLength, kCFStringEncodingUTF8, false);
					if (!filename) { succeeded = NO; break; }
					if (ContainsHighAscii(name, nameLength)) {
						CFMutableStringRef normalizedFilename = CFStringCreateMutableCopy(
							kCFAllocatorDefault, 0, filename);
						CFRelease(filename);
						CFStringNormalize(normalizedFilename, kCFStringNormalizationFormC);
						filename = normalizedFilename;
					}
					if (!NVAppendCatalogEntry(&catalogEntries, &sortedCatalogEntries, &catEntriesCount,
						&totalCatEntriesCount, filename, changeTime, documentID, fileID,
						generationCount)) {
						succeeded = NO;
						break;
					}
				}
				recordBytes += recordLength;
			}
			if (!succeeded) break;
		}
		if (transientFailure) {
			if (!attempt) continue;
			[self _resetCatalogEntries];
			return NO;
		}
		if (!succeeded || useFoundation) {
			NSLog(@"Bulk directory metadata was malformed or incomplete; using Foundation");
			[self _resetCatalogEntries];
			succeeded = [self _readFilesUsingFoundation];
		}
		for (size_t index = 0; index < catEntriesCount; index++)
			sortedCatalogEntries[index] = &catalogEntries[index];
		return succeeded;
	}
	return NO;
}

- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry {
	/*
	 * A catalog ctime mismatch means "some file state changed," not necessarily
	 * that the data fork changed.  Preserve the historical behavior of reloading
	 * content and tags together, but only after the cheap snapshot detects that
	 * mismatch.  If NV has unwritten edits, memory wins and the scheduled write
	 * will replace the external version; identity is still refreshed so a rename
	 * in that interval continues to follow the correct file.
	 * TODO: Preserve the stable external and base contents in this conflict path
	 * and use diff-match-patch to merge them into the unwritten in-memory note
	 * before its pending write is allowed to replace the file.
	 */
	struct timespec previousChangeTime = fileAttributeChangeTimeOfNote(aNoteObject);
	BOOL metadataChanged = !fileMetadataIsValidForNote(aNoteObject) ||
		previousChangeTime.tv_sec != catEntry->attributeChangeTime.tv_sec ||
		previousChangeTime.tv_nsec != catEntry->attributeChangeTime.tv_nsec ||
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
				
				if (![self modifyNoteIfNecessary:currentNotes[i] usingCatalogEntry:catEntriesPtrs[j]])
					return NO;
				
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
		if (![self processNotesAddedByIdentity:addedEntries removed:removedEntries]) return NO;
	} else {
		
		if (![removedEntries count]) {
			for (i=0; i<[addedEntries count]; i++) {
				NSError *error = nil;
				NoteCatalogEntry *entry = [[addedEntries objectAtIndex:i] pointerValue];
				if (![self prepareNoteAdditionFromCatalogEntry:entry error:&error]) {
					NSLog(@"Could not import note '%@': %@", entry->filename, error);
					return NO;
				}
			}
		}
		
		if (![addedEntries count]) {
			[self _stageOrAddDeletedNotes:removedEntries];
		}
	}
	return YES;
}

- (BOOL)_matchAddedEntries:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries
	usingDocumentIdentifiers:(BOOL)useDocumentIdentifiers {
	/*
	 * Match only identifiers unique on both sides.  Zero means unavailable, and
	 * duplicate values are ambiguous, so either condition must fall through rather
	 * than guessing.  Callers qualify persistent 32-bit document IDs by volume;
	 * 64-bit file IDs are deliberately session-only and never archived.  Darwin's
	 * generation count is a revision counter—it changes on ordinary edits—so it is
	 * an invalidation token, not an incarnation qualifier for rename matching.
	 * Iterate a copy because successful pairs are removed from both work lists.
	 */
	NSMutableDictionary *removedByIdentifier = [NSMutableDictionary dictionary];
	for (NoteObject *note in removedEntries) {
		uint64_t identifier = useDocumentIdentifiers ? documentIDOfNote(note) : sessionFileIDOfNote(note);
		if (!identifier) continue;
		NSNumber *key = [NSNumber numberWithUnsignedLongLong:identifier];
		[removedByIdentifier setObject:[removedByIdentifier objectForKey:key] ? (id)[NSNull null] : note
			forKey:key];
	}
	NSMutableDictionary *addedCounts = [NSMutableDictionary dictionary];
	for (NSValue *value in addedEntries) {
		NoteCatalogEntry *entry = [value pointerValue];
		uint64_t identifier = useDocumentIdentifiers ? entry->documentID : entry->fileID;
		if (!identifier) continue;
		NSNumber *key = [NSNumber numberWithUnsignedLongLong:identifier];
		[addedCounts setObject:[NSNumber numberWithUnsignedInteger:
			[[addedCounts objectForKey:key] unsignedIntegerValue] + 1] forKey:key];
	}
	for (NSValue *value in [[addedEntries copy] autorelease]) {
		NoteCatalogEntry *entry = [value pointerValue];
		uint64_t identifier = useDocumentIdentifiers ? entry->documentID : entry->fileID;
		NSNumber *key = [NSNumber numberWithUnsignedLongLong:identifier];
		id note = identifier && [[addedCounts objectForKey:key] unsignedIntegerValue] == 1 ?
			[removedByIdentifier objectForKey:key] : nil;
		if (!note || note == [NSNull null]) continue;
		NSLog(@"File %@ renamed by %@ to %@", filenameOfNote(note),
			useDocumentIdentifiers ? @"document identifier" : @"session file identifier", entry->filename);
		if (![self modifyNoteIfNecessary:note usingCatalogEntry:entry]) return NO;
		[addedEntries removeObjectIdenticalTo:value];
		[removedEntries removeObjectIdenticalTo:note];
		[removedByIdentifier removeObjectForKey:key];
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
	for (NSValue *value in addedEntries) {
		NoteCatalogEntry *entry = [value pointerValue];
		NSError *error = nil;
		if (![self prepareNoteAdditionFromCatalogEntry:entry error:&error]) {
			NSLog(@"Could not import note '%@': %@", entry->filename, error);
			return NO;
		}
	}
	if ([removedEntries count]) [self _stageOrAddDeletedNotes:removedEntries];
	return YES;
}

- (BOOL)processNotesAddedByContent:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	/*
	 * Content is the identity of last resort, so only a value unique on both sides
	 * may prove a rename.  Preflight every added file before committing deletions;
	 * one unreadable candidate otherwise made the old implementation delete a note
	 * and import a blank replacement.  The detached preflight value is reused by
	 * reconciliation; the final catalog fence validates it before commit.
	 * Identical-content groups remain ordinary additions and removals.
	 *
	 * rename candidate sets are normally tiny, so two dictionaries are
	 * simpler than restoring the old size-sorting/index machinery.
	 */
	NSMutableDictionary *addedByContent = [NSMutableDictionary dictionary];
	for (NSValue *value in addedEntries) {
		NoteCatalogEntry *entry = [value pointerValue];
		NSError *error = nil;
		NVNoteFileSnapshot snapshot;
		if (![self readNoteFileSnapshot:&snapshot forNoteNamed:(NSString*)entry->filename error:&error]) {
			NSLog(@"Could not inspect rename candidate '%@': %@", entry->filename, error);
			return NO;
		}
		NoteObject *prepared = [[[NoteObject alloc] initWithCatalogEntry:entry snapshot:&snapshot
			format:[self currentNoteStorageFormat] fallbackLabels:@""
			fallbackEncoding:NSUTF8StringEncoding fallbackCreatedDate:0.0 error:&error] autorelease];
		if (!prepared) {
			NSLog(@"Could not decode rename candidate '%@': %@", entry->filename, error);
			return NO;
		}
		[directoryTransaction->preparedCandidates setObject:prepared
			forKey:(NSString*)entry->filename];
		if (!snapshot.tags)
			[directoryTransaction->candidatesWithoutTags addObject:(NSString*)entry->filename];
		NSString *content = [[prepared contentString] string];
		if (!content) {
			NSLog(@"Could not decode rename candidate '%@'", entry->filename);
			return NO;
		}
		NSMutableArray *values = [addedByContent objectForKey:content];
		if (!values) {
			values = [NSMutableArray array];
			[addedByContent setObject:values forKey:content];
		}
		[values addObject:value];
	}

	NSMutableDictionary *removedByContent = [NSMutableDictionary dictionary];
	for (NoteObject *note in removedEntries) {
		NSString *content = [[note contentString] string];
		NSMutableArray *notes = [removedByContent objectForKey:content];
		if (!notes) {
			notes = [NSMutableArray array];
			[removedByContent setObject:notes forKey:content];
		}
		[notes addObject:note];
	}

	NSMutableArray *uniquePairs = [NSMutableArray array];
	for (NSString *content in addedByContent) {
		NSArray *values = [addedByContent objectForKey:content];
		NSArray *notes = [removedByContent objectForKey:content];
		if ([values count] == 1 && [notes count] == 1)
			[uniquePairs addObject:[NSArray arrayWithObjects:[values objectAtIndex:0],
				[notes objectAtIndex:0], nil]];
	}
	for (NSArray *pair in uniquePairs) {
		NSValue *value = [pair objectAtIndex:0];
		NoteObject *note = [pair objectAtIndex:1];
		NoteCatalogEntry *entry = [value pointerValue];
		NSLog(@"File %@ renamed by unique content to %@", filenameOfNote(note), entry->filename);
		if (![self modifyNoteIfNecessary:note usingCatalogEntry:entry]) return NO;
		[addedEntries removeObjectIdenticalTo:value];
		[removedEntries removeObjectIdenticalTo:note];
	}

	for (NSValue *value in addedEntries) {
		NoteCatalogEntry *entry = [value pointerValue];
		NSError *error = nil;
		if (![self prepareNoteAdditionFromCatalogEntry:entry error:&error]) {
			NSLog(@"Could not import note '%@': %@", entry->filename, error);
			return NO;
		}
	}
	if ([removedEntries count]) [self _stageOrAddDeletedNotes:removedEntries];
	return YES;
}

@end
