//
//  NotationController.m
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.

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


#import "NotationController.h"
#import "NSCollection_utils.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "BufferUtils.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NoteAttributeColumn.h"
#import "FrozenNotation.h"
#import "AlienNoteImporter.h"
#import "ExternalEditingSession.h"
#import "StartupRecovery.h"
#import "NotationSyncServiceManager.h"
#import "NotationDirectoryManager.h"
#import "SyncSessionController.h"
#import "BookmarksController.h"
#import "DeletionManager.h"
#import "NSData_transformations.h"
#import "NVRootedDirectory_Private.h"
#include <errno.h>
#include <unistd.h>

NSString * const NotesDatabaseFileName = @"Notes & Settings";

static id UnarchiveRootObject(NSData *data, NSError **error) {
	NSError *unarchiveError = nil;
	NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&unarchiveError] autorelease];
	[unarchiver setRequiresSecureCoding:NO];
	id object = [unarchiver decodeTopLevelObjectForKey:NSKeyedArchiveRootObjectKey error:&unarchiveError];
	[unarchiver finishDecoding];
	if (error) *error = unarchiveError;
	return object;
}

@interface NotationController (NVRootedDirectoryFactory)
- (NVRootedDirectory*)newRootedDirectoryForURL:(NSURL*)URL error:(NSError**)error;
@end

@interface NotationController ()
- (void)_removeNoteAfterExternalEditing:(NoteObject*)note;
- (void)_removeNotesAfterExternalEditing:(NSArray*)notes;
- (void)_externalEditingTeardownFailed;
- (id)_initWithRootedDirectory:(NVRootedDirectory*)directory recoveredNotes:(NSDictionary*)recoveredNotes
	stagingRecovery:(BOOL)stagingRecovery error:(OSStatus*)error;
@end

@implementation NotationController

- (NVRootedDirectory*)newRootedDirectoryForURL:(NSURL*)URL error:(NSError**)error {
	return [[NVRootedDirectory alloc] initWithFileReferenceURL:URL error:error];
}

@synthesize filterString = _filterString, directoryRetryTimer, changeWritingTimer, lastWriteError, walWriter;

- (id)init {
    self = [super init];
    if (self) {
		notesChanged = NO;
		
		allNotes = [[NSMutableArray alloc] init]; //<--the authoritative list of all memory-accessible notes
		deletedNotes = [[NSMutableSet alloc] init];
		labelsListController = [[LabelsListController alloc] init];
		prefsController = [GlobalPrefs defaultPrefs];
		notesListDataSource = [[FastListDataSource alloc] init];
		deletionManager = [[DeletionManager alloc] initWithNotationController:self];
		
		allNotesBuffer = NULL;
		allNotesBufferSize = 0;
		manglingString = currentFilterStr = NULL;
		lastWordInFilterStr = 0;
		selectedNoteIndex = NSNotFound;
		
		directoryCatalog = nil;

		lastLayoutStyleGenerated = -1;
		lastCheckedDateInHours = hoursFromAbsoluteTime(CFAbsoluteTimeGetCurrent());
		
		pendingFileWrites = [[NSMutableSet alloc] init];
		pendingJournalWrites = [[NSMutableSet alloc] init];
    }
    return self;
}


- (id)initWithAliasData:(NSData*)data error:(OSStatus*)err {
	NSData *bookmarkData = [data bookmarkDataFromLegacyAliasRecord];
	NVRootedDirectory *directory = [[NVRootedDirectory alloc]
		initWithBookmarkData:bookmarkData error:NULL];
	if (!directory) {
		if (err) *err = fnfErr;
		[self release];
		return nil;
	}
	self = [self initWithRootedDirectory:directory error:err];
	[directory release];
	return self;
}

- (id)initWithDefaultDirectoryReturningError:(OSStatus*)err {
	NSError *urlError = nil;
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *applicationSupportURL = [manager URLForDirectory:NSApplicationSupportDirectory
		inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&urlError];
	NSURL *directoryURL = [applicationSupportURL URLByAppendingPathComponent:@"Notational Data"
		isDirectory:YES];
	if (!applicationSupportURL || ![manager createDirectoryAtURL:directoryURL
		withIntermediateDirectories:NO
		attributes:@{ NSFilePosixPermissions: @0700 }
		error:&urlError]) {
		if (err) *err = ioErr;
		[self release];
		return nil;
	}
	directoryURL = [manager fileReferenceURLForURL:directoryURL error:&urlError];
	if (!directoryURL) {
		if (err) *err = fnfErr;
		[self release];
		return nil;
	}
	return [self initWithDirectoryURL:directoryURL error:err];
}

- (id)initWithDirectoryURL:(NSURL*)directoryURL error:(OSStatus*)err {
	if (![directoryURL isFileReferenceURL]) {
		if (err) *err = paramErr;
		[self release];
		return nil;
	}
	NSError *directoryOpenError = nil;
	NVRootedDirectory *directory = [self newRootedDirectoryForURL:directoryURL
		error:&directoryOpenError];
	if (!directory) {
		NSLog(@"Unable to open notes directory by reference: %@", directoryOpenError);
		if (err) *err = ioErr;
		[self release];
		return nil;
	}
	self = [self initWithRootedDirectory:directory error:err];
	[directory release];
	return self;
}

- (id)initWithRootedDirectory:(NVRootedDirectory*)directory error:(OSStatus*)err {
	return [self _initWithRootedDirectory:directory recoveredNotes:nil
		stagingRecovery:NO error:err];
}

- (id)_initWithRootedDirectory:(NVRootedDirectory*)directory recoveredNotes:(NSDictionary*)recoveredNotes
	stagingRecovery:(BOOL)stagingRecovery error:(OSStatus*)err {
	/* Normal initialization creates the WAL and, if one already exists, delegates
	 * the entire recovery transaction to StartupRecovery.  Staging initialization
	 * only loads a database and persists recoveredNotes while the coordinator
	 * continues to hold the old WAL lock.  It deliberately returns before WAL
	 * creation, format setup, and epoch upgrade so those steps happen once, after
	 * the old journal has been preserved.  A non-nil empty dictionary is meaningful:
	 * it forces an installed legacy database through the same verified checkpoint. */

	if (!directory) {
		if (err)
			*err = paramErr;
		[self release];
		return nil;
	}

	if (err)
		*err = noErr;

	self = [self init];
	if (self) {
		noteDirectory = [directory retain];
		//check writable and readable perms, warning user if necessary
		
		//first read cache file
		OSStatus anErr = noErr;
		if ((anErr = [self _readAndInitializeSerializedNotes]) != noErr) {
			if (err)
				*err = anErr;
			[self release];
			return nil;
		}
		
		if (stagingRecovery) {
			if ([recoveredNotes count]) [self processRecoveredNotes:recoveredNotes];
			if (recoveredNotes) notesChanged = YES;
			/* External note files are not part of the database/WAL rollback pair.
			 * Keep their obligations pending until StartupRecovery commits that pair. */
			NSSet *deferredFileWrites = [pendingFileWrites copy];
			[pendingFileWrites removeAllObjects];
			BOOL flushed = !recoveredNotes || [self flushAllNoteChanges];
			[pendingFileWrites unionSet:deferredFileWrites];
			[deferredFileWrites release];
			if (!flushed) {
				if (err) *err = kJournalingError;
				[self release];
				return nil;
			}
			return self;
		}

		if (![self initializeJournaling]) {
			OSStatus recoveryError = kJournalingError;
			NotationController *recoveredController =
				[self newControllerByRecoveringStartupJournal:err ?: &recoveryError];
			if (recoveredController) {
				[self release];
				return recoveredController;
			}
			if (err && *err == noErr) *err = recoveryError;
			[self release];
			return nil;
		}

		//set up the directory subscription, if necessary
		//and sync based on notes in directory and their mod. dates
		[self databaseSettingsChangedFromOldFormat:[notationPrefs notesStorageFormat]];
		
		[self upgradeDatabaseIfNecessary];
		/* Persist an upgrade without rotating the WAL.  A failed write retains its
		 * normal retry obligation and the active journal remains authoritative. */
		(void)[self flushAllNoteChanges];
		
		[self updateTitlePrefixConnections];
    }
    
	return self;
}

- (NSURL*)noteDirectoryURL {
	return [noteDirectory transientFileReferenceURL];
}

- (NVRootedDirectory*)noteDirectory { return noteDirectory; }

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)theDelegate {
	
	delegate = theDelegate;

}

- (BOOL)_removeSpuriousDatabaseFileNotes {
	// Remove notes accidentally imported from database artifacts, but leave the files intact.
	NoteObject *dbNote = nil, *walNote = nil;
	for (NoteObject *note in allNotes) {
		if (!dbNote && [filenameOfNote(note) isEqualToString:NotesDatabaseFileName])
			dbNote = [[note retain] autorelease];
		if (!walNote && [filenameOfNote(note) isEqualToString:NVJournalFilename])
			walNote = [[note retain] autorelease];
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

- (void)upgradeDatabaseIfNecessary {
	if (![notationPrefs firstTimeUsed]) {
		
		const UInt32 epochIteration = [notationPrefs epochIteration];
		
		if (epochIteration < 3) {
			[allNotes makeObjectsPerformSelector:@selector(writeFileDatesAndUpdateTrackingInfo)];
		}
		if (epochIteration < 4) {
			if ([self _removeSpuriousDatabaseFileNotes]) {
				NSLog(@"found and removed spurious DB notes");
				[self refilterNotes];
			}
			
			//TableColumnsVisible was renamed NoteAttributesVisible to coincide with shifted emphasis; remove old key to declutter prefs
			[[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TableColumnsVisible"];
			
			//remove and re-add link attributes for all notes
			//remove underline attribute for all notes
			//add automatic strike-through attribute for all notes
			[allNotes makeObjectsPerformSelector:@selector(_resanitizeContent)];
		}
		
		if (epochIteration < EPOC_ITERATION) {
			NSLog(@"epochIteration was upgraded from %u to %u", epochIteration, EPOC_ITERATION);
			notesChanged = YES;
		} else if ([notationPrefs epochIteration] > EPOC_ITERATION) {
			NSAlert *versionAlert = [[[NSAlert alloc] init] autorelease];
			[versionAlert setMessageText:NSLocalizedString(@"Warning: this database was created by a newer version of Notational Velocity. Continue anyway?", nil)];
			[versionAlert setInformativeText:NSLocalizedString(@"If you make changes, some settings and metadata will be lost.", nil)];
			[versionAlert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
			[versionAlert addButtonWithTitle:NSLocalizedString(@"Continue", nil)];
			[versionAlert setAlertStyle:NSAlertStyleCritical];
			if ([versionAlert runModal] == NSAlertFirstButtonReturn)
			exit(0);
		}
	}	
}

//used to ensure a newly-written Notes & Settings file is valid before finalizing the save
//read the file back from disk, deserialize it, decrypt and decompress it, and compare the notes roughly to our current notes
- (BOOL)verifyDatabaseData:(NSData*)archivedNotation error:(NSError**)error {
	
	NSDate *date = [NSDate date];
	OSStatus status = noErr, result = noErr;
	
	FrozenNotation *frozenNotation = nil;
	NSMutableArray *notesToVerify = nil;
	if (![archivedNotation length]) {
		result = eofErr;
		goto returnResult;
	}
	@try {
		NSError *unarchiveError = nil;
		frozenNotation = UnarchiveRootObject(archivedNotation, &unarchiveError);
		if (!frozenNotation) {
			NSLog(@"(VERIFY) Error unarchiving notes and preferences from data: %@", unarchiveError);
			result = kCoderErr;
			goto returnResult;
		}
	} @catch (NSException *e) {
		NSLog(@"(VERIFY) Error unarchiving notes and preferences from data (%@, %@)", [e name], [e reason]);
		result = kCoderErr;
		goto returnResult;
	}
	//unpack notes using the current NotationPrefs instance (not the just-unarchived one), with which we presumably just used to encrypt it
	notesToVerify = [[frozenNotation unpackedNotesWithPrefs:notationPrefs returningError:&status] retain];	
	if (noErr != status) {
		result = status;
		goto returnResult;
	}
	//notes were unpacked--now roughly compare notesToVerify with allNotes, plus deletedNotes and notationPrefs
	if (!notesToVerify || [notesToVerify count] != [allNotes count] || [[frozenNotation deletedNotes] count] != [deletedNotes  count] || 
		[[frozenNotation notationPrefs] notesStorageFormat] != [notationPrefs notesStorageFormat] ||
		[[frozenNotation notationPrefs] hashIterationCount] != [notationPrefs hashIterationCount]) {
		result = kItemVerifyErr;
		goto returnResult;
	}
	unsigned int i;
	for (i=0; i<[notesToVerify count]; i++) {
		if ([[[notesToVerify objectAtIndex:i] contentString] length] != [[[allNotes objectAtIndex:i] contentString] length]) {
			result = kItemVerifyErr;
			goto returnResult;
		}
	}
	
	NSLog(@"verified %lu notes in %g s", (unsigned long)[notesToVerify count], (float)[[NSDate date] timeIntervalSinceDate:date]);
returnResult:
	[notesToVerify release];
	if (result != noErr && error)
		*error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:nil];
	return result == noErr;
}


- (OSStatus)_readAndInitializeSerializedNotes {

    OSStatus err = noErr;
	NSError *readError = nil;
	NSData *notesData = [noteDirectory dataFromFileNamed:NotesDatabaseFileName error:&readError];
	if (!notesData && [[readError domain] isEqualToString:NSPOSIXErrorDomain] &&
		[readError code] == ENOENT) {
		NVFileWriteResult *createResult = [noteDirectory createFileNamed:NotesDatabaseFileName
			withData:[NSData data]];
		switch ([createResult disposition]) {
			case NVFileWriteInstalledVerified:
				notesData = [NSData data];
				break;
			case NVFileWriteNotInstalled:
				if ([[[createResult error] domain] isEqualToString:NSCocoaErrorDomain] &&
					[[createResult error] code] == NSFileWriteFileExistsError)
					notesData = [noteDirectory dataFromFileNamed:NotesDatabaseFileName error:&readError];
				else readError = [createResult error];
				break;
			case NVFileWriteInstalledNeedsReconciliation:
				readError = [createResult error];
				break;
		}
	}
	if (!notesData) {
		NSLog(@"Could not read notes database: %@", readError);
		return ioErr;
	}
	
	FrozenNotation *frozenNotation = nil;
	
	if ([notesData length] > 0) {
		@try {
			NSError *unarchiveError = nil;
			frozenNotation = UnarchiveRootObject(notesData, &unarchiveError);
			if (!frozenNotation) {
				NSLog(@"Error unarchiving notes and preferences from data: %@", unarchiveError);
				return kCoderErr;
			}
		} @catch (NSException *e) {
			NSLog(@"Error unarchiving notes and preferences from data (%@, %@)", [e name], [e reason]);
			//perhaps this shouldn't be an error, but the user should instead have the option of overwriting the DB with a new one?
			return kCoderErr;
		}
	}
	
	
	[notationPrefs release];
	
	if (!(notationPrefs = [[frozenNotation notationPrefs] retain]))
		notationPrefs = [[NotationPrefs alloc] init];
	[notationPrefs setDelegate:self];

	[self initializeFileMetadataVolumeUUID];
	
	[allNotes release];
	
	syncSessionController = [[SyncSessionController alloc] initWithSyncDelegate:self notationPrefs:notationPrefs];
	
	//frozennotation will work out passwords, keychains, decryption, etc...
	if (!(allNotes = [[frozenNotation unpackedNotesReturningError:&err] retain])) {
		//notes could be nil because the user cancelled password authentication
		//or because they were corrupted, or for some other reason
		if (err != noErr)
			return err;
		
		allNotes = [[NSMutableArray alloc] init];
	} else {
		[allNotes makeObjectsPerformSelector:@selector(attachToDelegate:) withObject:self];
		if (![self archivedFileMetadataIsForCurrentVolume])
			[allNotes makeObjectsPerformSelector:@selector(invalidateFileMetadata)];
	}
	
	[deletedNotes release];
	if (!(deletedNotes = [[frozenNotation deletedNotes] retain]))
	    deletedNotes = [[NSMutableSet alloc] init];
			
	[prefsController setNotationPrefs:notationPrefs sender:self];
	
	[self makeForegroundTextColorMatchGlobalPrefs];
	
	return noErr;
}

- (BOOL)initializeJournaling {
	if (self.walWriter) return YES;
	WALStorageController *writer = [[WALStorageController alloc]
		initWithRootedDirectory:noteDirectory
		encryptionKey:[notationPrefs WALSessionKey]];
	/* Keep the property as the sole owner: recovery rollback must be able to
	 * release the writer's flock immediately by clearing walWriter. */
	self.walWriter = writer;
	[writer release];
	return self.walWriter != nil;
}

//stick the newest unique recovered notes into allNotes
- (void)processRecoveredNotes:(NSDictionary*)dict {
	/* Values own their UUID bytes, so enumerating them directly avoids a second,
	 * fallible key/value allocation while the only copy may still be in the WAL. */
	for (id<SynchronizedNote> obj in [dict objectEnumerator]) {
			CFUUIDBytes *objUUIDBytes = [obj uniqueNoteIDBytes];
			
			NSUInteger existingNoteIndex = [allNotes indexOfNoteWithUUIDBytes:objUUIDBytes];
			
			if ([obj isKindOfClass:[DeletedNoteObject class]]) {
				
				if (existingNoteIndex != NSNotFound) {
					
					NoteObject *existingNote = [allNotes objectAtIndex:existingNoteIndex];
					if ([existingNote youngerThanLogObject:obj]) {
						NSLog(@"got a newer deleted note %@", obj);
						//except that normally the undomanager doesn't exist by this point			
						[self _registerDeletionUndoForNote:existingNote];
						[allNotes removeObjectAtIndex:existingNoteIndex];
						//try to use use the deleted note object instead of allowing _addDeletedNote: to make a new one, to preserve any changes to the syncMD
						[self _addDeletedNote:obj];
						notesChanged = YES;
					} else {
						NSLog(@"got an older deleted note %@", obj);
					}
				} else {
					NSLog(@"got a deleted note with a UUID that doesn't match anything in allNotes, adding to deletedNotes only");
					//must remember that this was deleted; b/c it could've been added+synced and then deleted before syncing the deletion
					//and it might not be in allNotes because the WALreader would have already coalesced by UUID, and so the next sync might re-add the note
					[self _addDeletedNote:obj];
				}
			} else if (existingNoteIndex != NSNotFound) {
				
				if ([[allNotes objectAtIndex:existingNoteIndex] youngerThanLogObject:obj]) {
					// NSLog(@"replacing old note with new: %@", [[(NoteObject*)obj contentString] string]);
					
					NoteObject *existingNote = [allNotes objectAtIndex:existingNoteIndex];
					if ([notationPrefs notesStorageFormat] != SingleDatabaseFormat)
						[(NoteObject*)obj setFileMergeBaseFromNote:existingNote];
					[existingNote disconnectLabels];
					[(NoteObject*)obj attachToDelegate:self];
					[allNotes replaceObjectAtIndex:existingNoteIndex withObject:obj];
					if ([notationPrefs notesStorageFormat] != SingleDatabaseFormat) {
						[(NoteObject*)obj requireFileWrite];
						[pendingFileWrites addObject:obj];
					}
					notesChanged = YES;
				} else {
					// NSLog(@"note %@ is not being replaced because its LSN is %u, while the old note's LSN is %u", 
					//  [[(NoteObject*)obj contentString] string], [(NoteObject*)obj logSequenceNumber], [[allNotes objectAtIndex:existingNoteIndex] logSequenceNumber]);
				}
			} else {
				//NSLog(@"Found new note: %@", [(NoteObject*)obj contentString]);
				
				[self _addNote:obj];
				if ([notationPrefs notesStorageFormat] != SingleDatabaseFormat) {
					[(NoteObject*)obj requireFileWrite];
					[pendingFileWrites addObject:obj];
				}
			}
	}
}

- (void)closeJournal {
    //remove journal file if we have one
    if (walWriter) {
		if (![walWriter destroyLogFile])
			NSLog(@"couldn't remove wal file--is this an error for note flushing?");
		
		self.walWriter = nil;
    }
}

- (void)checkJournalExistence {
    if (walWriter && ![walWriter logFileStillExists])
	[self performSelector:@selector(handleJournalError) withObject:nil afterDelay:0.0];
}

- (void)flushEverything {
	
	//if we could flush the database and there was a journal, then close it
	if ([self flushAllNoteChanges] && walWriter) {
		[self closeJournal];
		
		//re-start the journal if we had one
		if (![self initializeJournaling]) {
			[self performSelector:@selector(handleJournalError) withObject:nil afterDelay:0.0];
		}
	}
}

- (BOOL)flushAllNoteChanges {
    //write only if preferences or notes have been changed
	if (notesChanged || [notationPrefs preferencesChanged] || [pendingFileWrites count] ||
		[pendingJournalWrites count]) {
		
		//finish writing notes and/or db journal entries
		[self synchronizeNoteChanges:changeWritingTimer];	
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNoteChanges:) object:nil];
		if ([pendingFileWrites count] || [pendingJournalWrites count]) return NO;
		
		if (walWriter) {
			if (![walWriter synchronize]) {
				NSLog(@"Couldn't sync wal file");
				writeRetryPending = YES;
				[self _scheduleFilesystemRetryTimer];
				return NO;
			}
			[NSObject cancelPreviousPerformRequestsWithTarget:self
				selector:@selector(_synchronizeJournalOutbox) object:nil];
		}
		
		NSData *serializedData = [FrozenNotation frozenDataWithExistingNotes:allNotes deletedNotes:deletedNotes prefs:notationPrefs];
		if (!serializedData) {
			
			NSLog(@"serialized data is nil!");
			return NO;
		}
		
		//we should have all journal records on disk by now
		NVFileWriteResult *writeResult = [noteDirectory overwriteFileNamed:NotesDatabaseFileName
			withData:serializedData
			preparedDataVerifier:^BOOL(NSData *readBackData, NSError **verificationError) {
				return [self verifyDatabaseData:readBackData error:verificationError];
			}];
		switch ([writeResult disposition]) {
			case NVFileWriteInstalledVerified:
				break;
			case NVFileWriteNotInstalled:
			case NVFileWriteInstalledNeedsReconciliation:
				NSLog(@"Database save remains pending: %@", [writeResult error]);
				writeRetryPending = YES;
				[self _scheduleFilesystemRetryTimer];
				return NO;
		}
		/* The writer reports the verified installation, not transaction durability.
		 * Keep the WAL-backed database change pending until this explicit boundary. */
		NSError *directoryError = nil;
		if (![noteDirectory synchronize:&directoryError]) {
			NSLog(@"Database save remains pending: %@", directoryError);
			writeRetryPending = YES;
			[self _scheduleFilesystemRetryTimer];
			return NO;
		}
		
		[notationPrefs setPreferencesAreStored];
		notesChanged = NO;
		
    }
	if (![pendingFileWrites count] && ![pendingJournalWrites count]) {
		writeRetryPending = NO;
		if (!directoryRetryPending && directoryRetryTimer) {
			[directoryRetryTimer invalidate];
			self.directoryRetryTimer = nil;
			directoryRetryAttempt = 0;
		}
	}
    return YES;
}

- (void)handleJournalError {
    
    //we can be static because the resulting action (exit) is global to the app
    static BOOL displayedAlert = NO;
    
    if (delegate && !displayedAlert) {
	//we already have a delegate, so this must be a result of the format or file changing after initialization
	
	displayedAlert = YES;
	
	[self flushAllNoteChanges];
	
	NSAlert *interimAlert = [[[NSAlert alloc] init] autorelease];
	[interimAlert setMessageText:NSLocalizedString(@"Unable to create or access the Interim Note-Changes file. Is another copy of Notational Velocity currently running?", nil)];
	[interimAlert setInformativeText:NSLocalizedString(@"Open Console in /Applications/Utilities/ for more information.", nil)];
	[interimAlert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
	[interimAlert setAlertStyle:NSAlertStyleCritical];
	[interimAlert runModal];
	
	
	exit(1);
    }
}

//notation prefs delegate method
- (void)databaseEncryptionSettingsChanged {
	//we _must_ re-init the journal (if fmt is single-db and jrnl exists) in addition to flushing DB
	[self flushEverything];
	
	//called whenever note-storage format or encryption-activation changes
	[[ExternalEditingSession sharedExternalEditingSession] initializeDatabase:notationPrefs];
}

//notation prefs delegate method
- (void)databaseSettingsChangedFromOldFormat:(int)oldFormat {
	int currentStorageFormat = [notationPrefs notesStorageFormat];
    
	if (!walWriter && ![self initializeJournaling]) {
		[self performSelector:@selector(handleJournalError) withObject:nil afterDelay:0.0];
	}
	
    if (currentStorageFormat == SingleDatabaseFormat) {
		
		[self stopFileNotifications];
		
    } else {
		//write to disk any unwritten notes; do this before flushing database to make sure that when it is flushed, it gets the new file mod. dates
		//otherwise it would be necessary to set notesChanged = YES; after this method
		
		/* Changing to a separate-file format makes the live model authoritative.
		 * Queue every note before scanning so an existing external file cannot win
		 * through a racy existence/mtime preflight. */
		BOOL changingFormat = currentStorageFormat != oldFormat;
		if (changingFormat) {
			/* The preference setter flushed and reconciled the source format first,
			 * so conversion can treat the live model as authoritative. */
			for (NoteObject *note in allNotes) {
				if (oldFormat == SingleDatabaseFormat)
					note->currentFormatID = SingleDatabaseFormat;
				[note requireFileWrite];
				[pendingFileWrites addObject:note];
			}
		}

		[self startFileNotifications];
		
		if (!changingFormat) [self synchronizeNotesFromDirectory];
    }
	//perform after delay because this could trigger the mounting of a RAM disk in a background  NSTask
	[[ExternalEditingSession sharedExternalEditingSession] performSelector:@selector(initializeDatabase:) withObject:notationPrefs afterDelay:0.0];
}

- (int)currentNoteStorageFormat {
    return [notationPrefs notesStorageFormat];
}

- (void)noteDidNotWrite:(NoteObject*)note error:(NSError*)error {
	if (!error) return;
	if ([[error domain] isEqualToString:NVNoteStorageErrorDomain] &&
		[error code] == NVNoteStorageAtomicRecoveryError) {
		[pendingFileWrites removeObject:note];
		[self performSelector:@selector(synchronizeNotesFromDirectory)
			withObject:nil afterDelay:0.0];
	}
    if (![lastWriteError isEqual:error]) {
		NSAlert *writeAlert = [[[NSAlert alloc] init] autorelease];
		[writeAlert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Changed notes could not be saved because %@.", @"alert title appearing when notes couldn't be written"),
			[error localizedDescription]]];
		[writeAlert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
		[writeAlert setAlertStyle:NSAlertStyleWarning];
		[writeAlert runModal];
		
		self.lastWriteError = error;
    }
}

- (void)synchronizeNoteChanges:(NSTimer*)timer {
	BOOL attemptedWrites = [pendingFileWrites count] || [pendingJournalWrites count];
	if (attemptedWrites) {
		self.lastWriteError = nil;
		if ([notationPrefs notesStorageFormat] != SingleDatabaseFormat) {
			for (NoteObject *note in [[pendingFileWrites copy] autorelease])
				if ([note writeUsingCurrentFileFormatIfNecessary]) [pendingFileWrites removeObject:note];
		} else {
			[pendingFileWrites removeAllObjects];
		}
		if (walWriter) {
			for (NoteObject *note in [[pendingJournalWrites copy] autorelease])
				if ([note writeUsingJournal:walWriter]) [pendingJournalWrites removeObject:note];
		}
		[self scheduleUpdateListForAttribute:NoteDateModifiedColumnString];
		BOOL noteObligationsRemain = [pendingFileWrites count] || [pendingJournalWrites count];
		if (noteObligationsRemain) {
			writeRetryPending = YES;
			[self _scheduleFilesystemRetryTimer];
		} else if (!writeRetryPending && !directoryRetryPending && directoryRetryTimer) {
			[directoryRetryTimer invalidate];
			self.directoryRetryTimer = nil;
			directoryRetryAttempt = 0;
		}
	}
    
	if (changeWritingTimer) {
		[changeWritingTimer invalidate];
		self.changeWritingTimer = nil;
    }
}

- (void)_synchronizeJournalOutbox {
	if (walWriter && ![walWriter synchronize]) {
		writeRetryPending = YES;
		[self _scheduleFilesystemRetryTimer];
	} else if (![pendingFileWrites count] && ![pendingJournalWrites count]) {
		writeRetryPending = NO;
		if (!directoryRetryPending && directoryRetryTimer) {
			[directoryRetryTimer invalidate];
			self.directoryRetryTimer = nil;
			directoryRetryAttempt = 0;
		}
	}
}

- (void)closeAllResources {
	[allNotes makeObjectsPerformSelector:@selector(abortEditingInExternalEditor)];
	
	[deletionManager cancelPanelReturningCode:NSModalResponseStop];
	[self stopSyncServices];
	[self stopFileNotifications];
	BOOL flushed = [self flushAllNoteChanges];
	/* A failed final flush normally schedules another filesystem retry.  During
	 * shutdown that timer would retain this controller forever, so retire only
	 * the scheduling obligation; the pending note/WAL state remains intact. */
	writeRetryPending = NO;
	[self _cancelDirectoryRetry];
	if (flushed)
		[self closeJournal];
	[allNotes makeObjectsPerformSelector:@selector(disconnectLabels)];
}

- (void)trashRemainingNoteFilesInDirectory {
	NSAssert([notationPrefs notesStorageFormat] == SingleDatabaseFormat, @"We shouldn't be removing files if the storage is not single-database");	
	[allNotes makeObjectsPerformSelector:@selector(moveFileToTrash)];
}

- (void)updateLinksToNote:(NoteObject*)aNoteObject fromOldName:(NSString*)oldname {
    //O(n)
}

- (void)updateTitlePrefixConnections {
	//used to auto-complete titles to the first, shortest title of the same prefix--
	//to prevent auto-completing "Chicago Brauhaus" before "Chicago" when search string is "Chi", for example.
	//builds a tree-overlay in the list of notes, to find, for any given note, 
	//all other notes whose complete titles are a prefix of it
	
	//***
	//*** this method must run after any note is added, deleted, or retitled **
	//***
	
	if (![prefsController autoCompleteSearches] || ![allNotes count])
		return;
	
	//sort alphabetically to find shorter prefixes first
	NSMutableArray *allNotesAlpha = [allNotes mutableCopy];
	[allNotesAlpha sortStableUsingFunction:compareTitleString usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
	[allNotes makeObjectsPerformSelector:@selector(removeAllPrefixParentNotes)];

	NSUInteger j, i = 0, count = [allNotesAlpha count];
	for (i=0; i<count - 1; i++) {
		NoteObject *shorterNote = [allNotesAlpha objectAtIndex:i];
		BOOL isAPrefix = NO;
		//scan all notes sorted beneath this one for matching prefixes
		j = i + 1;
		do {
			NoteObject *longerNote = [allNotesAlpha objectAtIndex:j];
			if ((isAPrefix = noteTitleIsAPrefixOfOtherNoteTitle(longerNote, shorterNote))) {
				[longerNote addPrefixParentNote:shorterNote];
			}
		} while (isAPrefix && ++j<count);
	}

	[allNotesAlpha release];
}

- (void)addNewNote:(NoteObject*)note {
	if (!note) return;
    [self _addNote:note];
	
	//clear aNoteObject's syncServicesMD to facilitate sync recreation upon undoing of deletion
	//new notes should not have any sync MD; if they do, they should be added using -addNotesFromSync:
	//problem is that note could very likely still be in the process of syncing, in which case these dicts will be accessed
	//for simplenote is is necessary only once the iPhone app has fully deleted the note off the server; otherwise a regular update will recreate it
    
	[note makeNoteDirtyUpdateTime:YES updateFile:YES];
	
	[self updateTitlePrefixConnections];
	
	//force immediate update
	[self synchronizeNoteChanges:nil];
	
	if ([[self undoManager] isUndoing]) {
		//prohibit undoing of creation--only redoing of deletion
		//NSLog(@"registering %s", _cmd);
		[undoManager registerUndoWithTarget:self selector:@selector(removeNote:) object:note];
		if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
			[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Create Note quotemark%@quotemark",@"undo action name for creating a single note"), titleOfNote(note)]];
	}
    
	[self resortAllNotes];
    [self refilterNotes];
    
    [delegate notation:self revealNote:note options:NVEditNoteToReveal | NVOrderFrontWindow];	
}

- (void)addNotesFromSync:(NSArray<NoteObject*>*)noteArray {
	
	if (![noteArray count]) return; 
	
	if ([[self undoManager] isUndoing]) [undoManager beginUndoGrouping];
	for (NoteObject *note in noteArray) {
		[self _addNote:note];
		
		[note makeNoteDirtyUpdateTime:NO updateFile:YES];
		
		//absolutely ensure that this note is pushed to the rest of the services
		[note registerModificationWithOwnedServices];
		[self schedulePushToAllSyncServicesForNote:note];
	}
	if ([[self undoManager] isUndoing]) [undoManager endUndoGrouping];
	//don't need to reverse-register undo because removeNote/s: will never use this method
	
	[self updateTitlePrefixConnections];
	
	[self synchronizeNoteChanges:nil];
		
	[self resortAllNotes];
	[self refilterNotes];
}

- (void)addNotes:(NSArray<NoteObject*>*)noteArray {
	
	if (![noteArray count]) return; 
	
	if ([[self undoManager] isUndoing]) [undoManager beginUndoGrouping];
	for (NoteObject *note in noteArray) {
		[self _addNote:note];
		
		[note makeNoteDirtyUpdateTime:YES updateFile:YES];
	}
	if ([[self undoManager] isUndoing]) [undoManager endUndoGrouping];
	
	[self updateTitlePrefixConnections];
	
	[self synchronizeNoteChanges:nil];
	
	if ([[self undoManager] isUndoing]) {
		//prohibit undoing of creation--only redoing of deletion
		//NSLog(@"registering %s", _cmd);
		[undoManager registerUndoWithTarget:self selector:@selector(removeNotes:) object:noteArray];		
		if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
				[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Add %lu Notes", @"undo action name for creating multiple notes"), (unsigned long)[noteArray count]]];
	}
	[self resortAllNotes];
	[self refilterNotes];
	
	if ([noteArray count] > 1)
		[delegate notation:self revealNotes:noteArray];
	else
		[delegate notation:self revealNote:[noteArray lastObject] options:NVOrderFrontWindow];
}

- (void)note:(NoteObject*)note attributeChanged:(NSString*)attribute {
	
	if ([attribute isEqualToString:NotePreviewString]) {
		if ([prefsController tableColumnsShowPreview]) {
			NSUInteger idx = [notesListDataSource indexOfObjectIdenticalTo:note];
			if (NSNotFound != idx) {
				[delegate rowShouldUpdate:idx];
			}
		}
		//this attribute is not displayed as a column
		return;
	}
	
	//[self scheduleUpdateListForAttribute:attribute];
	[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:0.0];

	//special case for title requires this method, as app controller needs to know a few note-specific things
	if ([attribute isEqualToString:NoteTitleColumnString]) {
		[delegate titleUpdatedForNote:note];
		
		//also update notationcontroller's psuedo-prefix tree for autocompletion
		[self updateTitlePrefixConnections];
		//should perhaps instead trigger a coalesced notification that also updates wiki-link-titles
	}
}

- (BOOL)openFiles:(NSArray*)filenames {
	//reveal notes that already exist with any of these filenames
	//for paths left over that weren't in the notes-folder/database, import those files as new notes
	
	if (![filenames count]) return NO;
	
	NSArray *unknownPaths = filenames; //(this is not a requirement for -notesWithFilenames:unknownFiles:)
	
	if ([self currentNoteStorageFormat] != SingleDatabaseFormat) {
		//notes are stored as separate files, so if these paths are in the notes folder then NV can claim ownership over them
		
		//probably should sync directory here to make sure notesWithFilenames has the freshest data
		[self synchronizeNotesFromDirectory];
		
		NSSet *existingNotes = [self notesWithFilenames:filenames unknownFiles:&unknownPaths];
		if ([existingNotes count] > 1) {
			[delegate notation:self revealNotes:[existingNotes allObjects]];
		} else if ([existingNotes count] == 1) {
			[delegate notation:self revealNote:[existingNotes anyObject] options:NVEditNoteToReveal];
		}
		if (![unknownPaths count]) return [existingNotes count] > 0;
	}
	//NSLog(@"paths not found in DB: %@", unknownPaths);
	NSArray *createdNotes = [[[[AlienNoteImporter alloc] initWithStoragePaths:unknownPaths] autorelease] importedNotes];
	if (!createdNotes) return NO;
	
	[self addNotes:createdNotes];
	
	return YES;
}



- (void)scheduleUpdateListForAttribute:(NSString*)attribute {
	
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(scheduleUpdateListForAttribute:) object:attribute];
	
	if ([[sortColumn identifier] isEqualToString:attribute]) {
		
		if ([delegate notationListShouldChange:self]) {
			[self sortAndRedisplayNotes];
		} else {
			[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:1.5];
		}
	} else {
		//catch col updates even if they aren't the sort key
		
		NSEnumerator *enumerator = [[prefsController visibleTableColumns] objectEnumerator];
		NSString *colIdentifier = nil;
		
		//check to see if appropriate col is visible
		while ((colIdentifier = [enumerator nextObject])) {
			if ([colIdentifier isEqualToString:attribute]) {
				if ([delegate notationListShouldChange:self]) {
					[delegate notationListMightChange:self];
					[delegate notationListDidChange:self];
				} else {
					[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:1.5];
				}
				break;
			}
		}
	}
}

- (BOOL)makeNoteDurableForExternalEditing:(NoteObject*)note {
	/* The scratch file is the only other copy of an accepted external edit. Write
	 * and fsync its note record before ExternalEditingSession replaces or removes that file. */
	if (![allNotes containsObject:note]) return NO;
	if (!walWriter) return [self flushAllNoteChanges];
	if ([pendingJournalWrites containsObject:note]) {
		if (![note writeUsingJournal:walWriter]) return NO;
		[pendingJournalWrites removeObject:note];
	}
	if (walWriter && ![walWriter synchronize]) return NO;
	return YES;
}

- (void)scheduleWriteForNote:(NoteObject*)note {

	if ([allNotes containsObject:note]) {
	
		BOOL immediately = NO;
		notesChanged = YES;
		
		if ([notationPrefs notesStorageFormat] != SingleDatabaseFormat)
			[pendingFileWrites addObject:note];
		if (walWriter) [pendingJournalWrites addObject:note];
		
		//always synchronize absolutely no matter what 15 seconds after any change
		if (!changeWritingTimer)
			self.changeWritingTimer = [NSTimer scheduledTimerWithTimeInterval:(immediately ? 0.0 : 15.0) target:self
									 selector:@selector(synchronizeNoteChanges:)
									 userInfo:nil repeats:NO];
		
		//next user change always invalidates queued write from performSelector, but not queued write from timer
		//this avoids excessive writing and any potential and unnecessary disk access while user types
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNoteChanges:) object:nil];
		
		if (walWriter) {
			//perhaps a more general user interface activity timer would be better for this? update process syncs every 30 secs, anyway...
			[NSObject cancelPreviousPerformRequestsWithTarget:self
				selector:@selector(_synchronizeJournalOutbox) object:nil];
			//fsyncing WAL to disk can cause noticeable interruption when run from main thread
			[self performSelector:@selector(_synchronizeJournalOutbox) withObject:nil afterDelay:15.0];
		}
		
		if (!immediately) {
			//timer is already scheduled if immediately is true
			//queue to write 2.7 seconds after last user change; 
			[self performSelector:@selector(synchronizeNoteChanges:) withObject:nil afterDelay:2.7];
		}
	} else {
		NSLog(@"not writing note %@ because it is not controlled by NoteController", note);
	}
}

//the gatekeepers!
- (void)_addNote:(NoteObject*)aNoteObject {
	if (!aNoteObject) return;
	[aNoteObject attachToDelegate:self];
	
    [allNotes addObject:aNoteObject];
	[deletedNotes removeObject:aNoteObject];
    
    notesChanged = YES;
}

//the gateway methods must always show warnings, or else flash overlay window if show-warnings-pref is off
- (void)removeNotes:(NSArray*)noteArray {
	NSMutableArray *activeNotes = [NSMutableArray array];
	ExternalEditingSession *editor = [ExternalEditingSession sharedExternalEditingSession];
	for (NoteObject *note in noteArray)
		if ([editor hasActiveScratchEditingSessionForClient:note]) [activeNotes addObject:note];
	if ([activeNotes count]) {
		NSArray *notes = [[noteArray copy] autorelease];
		[editor finishScratchEditingSessionsForClients:activeNotes
			completionHandler:^(BOOL success) {
				if (success) [self _removeNotesAfterExternalEditing:notes];
				else [self _externalEditingTeardownFailed];
			}];
		return;
	}
	[self _removeNotesAfterExternalEditing:noteArray];
}

- (void)_removeNotesAfterExternalEditing:(NSArray*)noteArray {
	NSEnumerator *enumerator = [noteArray objectEnumerator];
	NoteObject* note;
	
	[undoManager beginUndoGrouping];
	while ((note = [enumerator nextObject])) {
		[self _removeNoteAfterExternalEditing:note];
	}
	[undoManager endUndoGrouping];
	if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
			[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Delete %lu Notes",@"undo action name for deleting notes"), (unsigned long)[noteArray count]]];
	
}

- (void)removeNote:(NoteObject*)aNoteObject {
	ExternalEditingSession *editor = [ExternalEditingSession sharedExternalEditingSession];
	if ([editor hasActiveScratchEditingSessionForClient:aNoteObject]) {
		[editor finishScratchEditingSessionsForClients:@[ aNoteObject ]
			completionHandler:^(BOOL success) {
				if (success) [self _removeNoteAfterExternalEditing:aNoteObject];
				else [self _externalEditingTeardownFailed];
			}];
		return;
	}
	[self _removeNoteAfterExternalEditing:aNoteObject];
}

- (void)_externalEditingTeardownFailed {
	NSLog(@"Could not finish external editing; the requested operation was canceled");
	NSBeep();
	if ([delegate respondsToSelector:@selector(externalEditingSessionTeardownFailed)])
		[delegate externalEditingSessionTeardownFailed];
}

- (void)_removeNoteAfterExternalEditing:(NoteObject*)aNoteObject {
    //reset linking labels and their notes
	if ([allNotes indexOfObjectIdenticalTo:aNoteObject] == NSNotFound) return;
    
	[aNoteObject retain];
	//Retire older file/journal writes before the deletion is recorded or the file is moved.
	//make sure that their LSNs are smaller than this deleted note's LSN
	[self synchronizeNoteChanges:nil];
	if ([notationPrefs notesStorageFormat] != SingleDatabaseFormat &&
		![aNoteObject moveFileToTrash]) {
		[aNoteObject release];
		return;
	}
	
	[aNoteObject disconnectLabels];
	
    [allNotes removeObjectIdenticalTo:aNoteObject];
	DeletedNoteObject *deletedNote = [self _addDeletedNote:aNoteObject];
	
	updateForVerifiedDeletedNote(deletionManager, aNoteObject);
    
    notesChanged = YES;
	
	//add journal removal event
	if (walWriter && ![walWriter writeRemovalForNote:aNoteObject]) {
		NSLog(@"Couldn't log note removal");
	}
	
	//a removal command will be sent to sync services if aNoteObject contains a matching syncServicesMD dict 
	//(e.g., already been synced at least once)
	//make sure we use the same deleted note that was added to the list of deleted notes, to simplify record-keeping
	//if the note didn't have metadata, try to sync it anyway so that the service knows this note shouldn't be created
	[self schedulePushToAllSyncServicesForNote: deletedNote ? deletedNote : [DeletedNoteObject deletedNoteWithNote:aNoteObject]];
    
	[self _registerDeletionUndoForNote:aNoteObject];
		
	//delete note from bookmarks, too
	[[prefsController bookmarksController] removeBookmarkForNote:aNoteObject];
	
	//rebuild the prefix tree, as this note may have been a prefix of another, or vise versa
	[self updateTitlePrefixConnections];
    
    [aNoteObject release];
    
    [self refilterNotes];
}

- (void)_purgeAlreadyDistributedDeletedNotes {
	//purge deletedNotes of objects without any more syncMD entries;
	//once a note has been deleted from all services, there's no need to keep it around anymore

	NSUInteger i = 0;
	NSArray *dnArray = [deletedNotes allObjects];
	for (i = 0; i<[dnArray count]; i++) {
		DeletedNoteObject *dnObj = [dnArray objectAtIndex:i];
		if (![[dnObj syncServicesMD] count]) {
			[deletedNotes removeObject:dnObj];
			notesChanged = YES;
		}
	}
	//NSLog(@"%s: deleted notes left: %@", _cmd, deletedNotes);
}

- (DeletedNoteObject*)_addDeletedNote:(id<SynchronizedNote>)aNote {
	//currently coupled to -[allNotes removeObjectIdenticalTo:]
	//don't need to remember this deleted note unless it was already synced with some service
	//furthermore, after that deleted note has been remotely-removed from all services with which it was previously synced,
	//can it be purged from this database once and for all?
	//e.g., each successful syncservice deletion would also remove that service's entry from syncServicesMD
	//when syncServicesMD was empty, it would be removed from the set
	//but what about synchronization systems without explicit delete APIs?
	
	if ([[aNote syncServicesMD] count]) {
		//it is important to use the actual deleted note if one is passed
		DeletedNoteObject *deletedNote = [aNote isKindOfClass:[DeletedNoteObject class]] ? aNote : [DeletedNoteObject deletedNoteWithNote:aNote];
		[deletedNotes addObject:deletedNote];
		notesChanged = YES;
		return deletedNote;
	}
	return nil;
}

- (void)removeSyncMDFromDeletedNotesInSet:(NSSet*)notesToOrphan forService:(NSString*)serviceName {
	NSMutableSet *matchingNotes = [deletedNotes setIntersectedWithSet:notesToOrphan];
	[matchingNotes makeObjectsPerformSelector:@selector(removeAllSyncMDForService:) withObject:serviceName];
}

- (void)_registerDeletionUndoForNote:(NoteObject*)aNote {	
	[undoManager registerUndoWithTarget:self selector:@selector(addNewNote:) object:aNote];			
	if (![undoManager isUndoing] && ![undoManager isRedoing])
		[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Delete quotemark%@quotemark",@"undo action name for deleting a single note"), titleOfNote(aNote)]];				
}			


- (void)setUndoManager:(NSUndoManager*)anUndoManager {
    [undoManager autorelease];
    undoManager = [anUndoManager retain];
}

- (NSUndoManager*)undoManager {
    return undoManager;
}

- (void)updateDateStringsIfNecessary {
	
	unsigned int currentHours = hoursFromAbsoluteTime(CFAbsoluteTimeGetCurrent());
	BOOL isHorizontalLayout = [prefsController horizontalLayout];
	
	if (currentHours != lastCheckedDateInHours || isHorizontalLayout != lastLayoutStyleGenerated) {
		lastCheckedDateInHours = currentHours;
		lastLayoutStyleGenerated = (int)isHorizontalLayout;
		
		[delegate notationListMightChange:self];
		resetCurrentDayTime();
		[allNotes makeObjectsPerformSelector:@selector(updateDateStrings)];
		[delegate notationListDidChange:self];
	}
}

- (void)makeForegroundTextColorMatchGlobalPrefs {
	NSColor *prefsFGColor = [notationPrefs foregroundColor];
	if (prefsFGColor) {
		NSColor *fgColor = [prefsController foregroundTextColor];
		
		if (!ColorsEqualWith8BitChannels(prefsFGColor, fgColor)) {			
			[self setForegroundTextColor:fgColor];
		}
	}
}

- (void)setForegroundTextColor:(NSColor*)fgColor {
	//do not update the notes in any other way, nor the database, other than also setting this color in notationPrefs
	//foreground color is archived only for practicality, and should be for display only
	NSAssert(fgColor != nil, @"foreground color cannot be nil");

	[allNotes makeObjectsPerformSelector:@selector(setForegroundTextColorOnly:) withObject:fgColor];
	
	[notationPrefs setForegroundTextColor:fgColor];
}

- (void)restyleAllNotes {
	NSFont *baseFont = [notationPrefs baseBodyFont];
	NSAssert(baseFont != nil, @"base body font from notation prefs should ALWAYS be valid!");
	
	[allNotes makeObjectsPerformSelector:@selector(updateUnstyledTextWithBaseFont:) withObject:baseFont];
	
	[notationPrefs setBaseBodyFont:[prefsController noteBodyFont]];
}

//used by BookmarksController

- (NoteObject*)noteForUUIDBytes:(CFUUIDBytes*)bytes {
	NSUInteger noteIndex = [allNotes indexOfNoteWithUUIDBytes:bytes];
	if (noteIndex != NSNotFound) return [allNotes objectAtIndex:noteIndex];
	return nil;	
}

- (void)updateLabelConnectionsAfterDecoding {
	[allNotes makeObjectsPerformSelector:@selector(updateLabelConnectionsAfterDecoding)];
}

//re-searching for all notes each time a label is added or removed is unnecessary, I think
- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet {
	[labelsListController addLabelSet:labelSet toNote:note];
        
    //this can only happen while the note is visible
	
	//[self refilterNotes];
}

- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet {
	[labelsListController removeLabelSet:labelSet fromNote:note];
        
	//[self refilterNotes];
}

- (void)filterNotesFromLabelAtIndex:(int)labelIndex {
	NSArray *notes = [[labelsListController notesAtFilteredIndex:labelIndex] allObjects];
	
	[delegate notationListMightChange:self];
	[notesListDataSource fillArrayFromArray:notes];
	
	[delegate notationListDidChange:self];	
}

- (void)filterNotesFromLabelIndexSet:(NSIndexSet*)indexSet {
	NSArray *notes = [[labelsListController notesAtFilteredIndexes:indexSet] allObjects];
	
	[delegate notationListMightChange:self];
	[notesListDataSource fillArrayFromArray:notes];
	
	[delegate notationListDidChange:self];
}

- (BOOL)filterNotesFromString:(NSString*)string {
	
	[delegate notationListMightChange:self];
	self.filterString = string;
	if ([self filterNotesFromUTF8String:[string lowercaseUTF8String] forceUncached:NO]) {
		[delegate notationListDidChange:self];
		
		return YES;
	}
	
	return NO;
}

- (void)refilterNotes {
	
    [delegate notationListMightChange:self];
    [self filterNotesFromUTF8String:(currentFilterStr ? currentFilterStr : "") forceUncached:YES];
    [delegate notationListDidChange:self];
}

- (BOOL)filterNotesFromUTF8String:(const char*)searchString forceUncached:(BOOL)forceUncached {
    BOOL stringHasExistingPrefix = YES;
    BOOL didFilterNotes = NO;
    size_t oldLen = 0, newLen = 0;
	NSUInteger i, initialCount = [notesListDataSource count];
    
	NSAssert(searchString != NULL, @"filterNotesFromUTF8String requires a non-NULL argument");
	
	newLen = strlen(searchString);
    
	//PHASE 1: determine whether notes can be searched from where they are--if not, start on all the notes
    if (!currentFilterStr || forceUncached || ((oldLen = strlen(currentFilterStr)) > newLen) ||
		strncmp(currentFilterStr, searchString, oldLen)) {
		
		//the search must be re-initialized; our strings don't have the same prefix
		
		[notesListDataSource fillArrayFromArray:allNotes];
		//[labelsListController unfilterLabels];
		
		stringHasExistingPrefix = NO;
		lastWordInFilterStr = 0;
		didFilterNotes = YES;
		
		//		NSLog(@"filter: scanning all notes");
    }
    
	
	//PHASE 2: actually search for notes
	NoteFilterContext filterContext;
	
	//if there is a quote character in the string, use that as a delimiter, as we will search by phrase
	//perhaps we could add some additional delimiters like punctuation marks here
    char *token, *separators = (strchr(searchString, '"') ? "\"" : " :\t\r\n");
    manglingString = replaceString(manglingString, searchString);
    
    BOOL touchedNotes = NO;
    
    if (!didFilterNotes || newLen > 0) {
		//only bother searching each note if we're actually searching for something
		//otherwise, filtered notes already reflect all-notes-state
		
		char *preMangler = manglingString + lastWordInFilterStr;
		while ((token = strsep(&preMangler, separators))) {
			
			if (*token != '\0') {
				//if this is the same token that we had scanned previously
				filterContext.useCachedPositions = stringHasExistingPrefix && (token == manglingString + lastWordInFilterStr);
				filterContext.needle = token;
				
				touchedNotes = YES;
				
				if ([notesListDataSource filterArrayUsingFunction:(BOOL (*)(id, void*))noteContainsUTF8String context:&filterContext])
					didFilterNotes = YES;
								
    lastWordInFilterStr = (int)(token - manglingString);
			}
		}
    }
    
	//PHASE 3: reset found pointers in case have been cleared
	NSUInteger filteredNoteCount = [notesListDataSource count];
	NoteObject const * const *notesBuffer = [notesListDataSource immutableObjects];
	
    if (didFilterNotes) {
		
		if (!touchedNotes) {
			//I can't think of any situation where notes were filtered and not touched--EXCEPT WHEN REMOVING A NOTE (>= vs. ==)
			NSAssert(filteredNoteCount >= [allNotes count], @"filtered notes were claimed to be filtered but were not");
			
			//reset found-ptr values; the search string was effectively blank and so no notes were examined
			for (i=0; i<filteredNoteCount; i++)
				resetFoundPtrsForNote((NoteObject*)notesBuffer[i]);
		}
		
		//we have to re-create the array at each iteration while searching notes, but not here, so we can wait until the end
		//[labelsListController recomputeListFromFilteredSet];
    }
    
	//PHASE 4: autocomplete based on results
	//even if the controller didn't filter, the search string could have changed its representation wrt spacing
	//which will still influence note title prefixes 
	selectedNoteIndex = NSNotFound;
	
    if (newLen && [prefsController autoCompleteSearches]) {

		for (i=0; i<filteredNoteCount; i++) {			
			//because we already searched word-by-word up there, this is just way simpler
			if (noteTitleHasPrefixOfUTF8String((NoteObject*)notesBuffer[i], searchString, newLen)) {
				selectedNoteIndex = i;
				//this note matches, but what if there are other note-titles that are prefixes of both this one and the search string?
				//find the first prefix-parent of which searchString is also a prefix
				NSUInteger j = 0, prefixParentIndex = NSNotFound;
				NSArray *prefixParents = prefixParentsOfNote((NoteObject*)notesBuffer[i]);
				
				for (j=0; j<[prefixParents count]; j++) {
					NoteObject *obj = [prefixParents objectAtIndex:j];
					
					if (noteTitleHasPrefixOfUTF8String(obj, searchString, newLen) &&
						(prefixParentIndex = [notesListDataSource indexOfObjectIdenticalTo:obj]) != NSNotFound) {
						//figure out where this prefix parent actually is in the list--if it actually is in the list, that is
						//otherwise look at the next prefix parent, etc.
						//the prefix parents array should always be alpha-sorted, so the shorter prefixes will always be first
						selectedNoteIndex = prefixParentIndex;
						break;
					}
				}
				break;
			}
		}
    }
    
    currentFilterStr = replaceString(currentFilterStr, searchString);
	
	if (!initialCount && initialCount == filteredNoteCount)
		return NO;
    
    return didFilterNotes;
}

- (NSUInteger)preferredSelectedNoteIndex {
    return selectedNoteIndex;
}

- (NSArray*)noteTitlesPrefixedByString:(NSString*)prefixString indexOfSelectedItem:(NSInteger *)anIndex {
	NSMutableArray *objs = [NSMutableArray arrayWithCapacity:[allNotes count]];
	const char *searchString = [prefixString lowercaseUTF8String];
	NSUInteger i, titleLen, strLen = strlen(searchString), j = 0, shortestTitleLen = UINT_MAX;

	for (i=0; i<[allNotes count]; i++) {
		NoteObject *thisNote = [allNotes objectAtIndex:i];
		if (noteTitleHasPrefixOfUTF8String(thisNote, searchString, strLen)) {
			[objs addObject:titleOfNote(thisNote)];
			if (anIndex && (titleLen = CFStringGetLength((CFStringRef)titleOfNote(thisNote))) < shortestTitleLen) {
				*anIndex = j;
				shortestTitleLen = titleLen;
			}
			j++;
		}
	}
	return objs;
}

- (NoteObject*)noteObjectAtFilteredIndex:(int)noteIndex {
	unsigned int theIndex = (unsigned int)noteIndex;
	
	if (theIndex < [notesListDataSource count])
		return [notesListDataSource immutableObjects][theIndex];
	
	return nil;
}

- (NSArray*)notesAtIndexes:(NSIndexSet*)indexSet {
	return [notesListDataSource objectsAtFilteredIndexes:indexSet];
}

//O(n^2) at best, but at least we're dealing with C arrays

- (NSIndexSet*)indexesOfNotes:(NSArray*)noteArray {
	NSMutableIndexSet *noteIndexes = [[NSMutableIndexSet alloc] init];
	
	NSUInteger i, noteCount = [noteArray count];

	id *notes = NULL;
	if (noteCount > 0) {
		notes = (id *)malloc(noteCount * sizeof(id));
		[noteArray getObjects:notes range:NSMakeRange(0, noteCount)];
	}
	
	for (i=0; i<noteCount; i++) {
		NSUInteger noteIndex = [notesListDataSource indexOfObjectIdenticalTo:notes[i]];
		
		if (noteIndex != NSNotFound)
			[noteIndexes addIndex:noteIndex];
	}
	
	if (notes != NULL) {
		free(notes);
	}
	
	return [noteIndexes autorelease];
}

- (NSUInteger)indexInFilteredListForNoteIdenticalTo:(NoteObject*)note {
	return [notesListDataSource indexOfObjectIdenticalTo:note];
}

- (NSUInteger)totalNoteCount {
	return [allNotes count];
}

- (NoteAttributeColumn*)sortColumn {
	return sortColumn;
}

- (void)setSortColumn:(NoteAttributeColumn*)col { 
	
    [sortColumn release];
	sortColumn = [col retain];
	
	[self sortAndRedisplayNotes];
}

//re-sort without refiltering, to avoid removing notes currently being edited
- (void)sortAndRedisplayNotes {
	
	[delegate notationListMightChange:self];

	NoteAttributeColumn *col = sortColumn;
	if (col) {
		BOOL reversed = [prefsController tableIsReverseSorted];
		NSInteger (*sortFunction) (id *, id *) = (reversed ? [col reverseSortFunction] : [col sortFunction]);
		NSInteger (*stringSortFunction) (id*, id*) = (reversed ? compareTitleStringReverse : compareTitleString);
		
		[allNotes sortStableUsingFunction:stringSortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		if (sortFunction != stringSortFunction)
			[allNotes sortStableUsingFunction:sortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		
		
		if ([notesListDataSource count] != [allNotes count]) {
				
			[notesListDataSource sortStableUsingFunction:stringSortFunction];	
		    if (sortFunction != stringSortFunction)
				[notesListDataSource sortStableUsingFunction:sortFunction];
			
		} else {
		    //mirror from allNotes; notesListDataSource is not filtered
		    [notesListDataSource fillArrayFromArray:allNotes];
		}
		
		[delegate notationListDidChange:self];
	}
}

- (void)resortAllNotes {
	
	NoteAttributeColumn *col = sortColumn;
	
	if (col) {
		BOOL reversed = [prefsController tableIsReverseSorted];
	
		NSInteger (*sortFunction) (id*, id*) = (reversed ? [col reverseSortFunction] : [col sortFunction]);
		NSInteger (*stringSortFunction) (id*, id*) = (reversed ? compareTitleStringReverse : compareTitleString);

		[allNotes sortStableUsingFunction:stringSortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		if (sortFunction != stringSortFunction)
			[allNotes sortStableUsingFunction:sortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
	}
}

- (float)titleColumnWidth {
	return titleColumnWidth;
}

- (void)regeneratePreviewsForColumn:(NSTableColumn*)col visibleFilteredRows:(NSRange)rows forceUpdate:(BOOL)force {

	CGFloat scrollerWidth = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:[NSScroller preferredScrollerStyle]];
	float width = [col width] - (float)scrollerWidth;
	
	if (force || roundf(width) != roundf(titleColumnWidth)) {
		titleColumnWidth = width;
		
		//regenerate previews for visible rows immediately and post a delayed message to regenerate previews for all rows
		if (rows.length > 0) {
			CFArrayRef visibleNotes = CFArrayCreate(NULL, (const void **)([notesListDataSource immutableObjects] + rows.location), rows.length, NULL);
			[(NSArray*)visibleNotes makeObjectsPerformSelector:@selector(updateTablePreviewString)];
			CFRelease(visibleNotes);
		}
		
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(regenerateAllPreviews) object:nil];
		[self performSelector:@selector(regenerateAllPreviews) withObject:nil afterDelay:0.0];
	}
}

- (void)regenerateAllPreviews {
	[allNotes makeObjectsPerformSelector:@selector(updateTablePreviewString)];
}

- (NotationPrefs*)notationPrefs {
	return notationPrefs;
}

- (id)labelsListDataSource {
    return labelsListController;
}

- (id)notesListDataSource {
    return notesListDataSource;
}

- (SyncSessionController*)syncSessionController {
	return syncSessionController;
}

- (void)dealloc {
	[directoryRetryTimer invalidate];
	[directoryRetryTimer release];
	[changeWritingTimer invalidate];
	[changeWritingTimer release];
	[walWriter release];
	[notationPrefs setDelegate:nil];
	[allNotes makeObjectsPerformSelector:@selector(attachToDelegate:) withObject:nil];

	[directoryCatalog release];
	if (allNotesBuffer)
		free(allNotesBuffer);
	free(currentFilterStr);
	free(manglingString);
    [undoManager release];
    [notesListDataSource release];
    [labelsListController release];
	[syncSessionController release];
	[deletionManager release];
    [allNotes release];
	[deletedNotes release];
	[notationPrefs release];
	[pendingFileWrites release];
	[pendingJournalWrites release];
	[_filterString release];
	[noteDirectory release];
	[currentFileMetadataVolumeUUID release];
	[lastWriteError release];
    
    [super dealloc];
}

@end
