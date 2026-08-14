#import "StartupRecovery.h"
#import "NotationDirectoryManager.h"
#import "NotationFileManager.h"
#import "NotationPrefs.h"
#import "WALController.h"
#import "ExternalEditingSession/ExternalEditingSession.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/*
 * Startup recovery theory of operation
 * ------------------------------------
 * Normal initialization first loads "Notes & Settings" and tries to create a
 * new "Interim Note-Changes" writer.  If the journal already exists, this
 * category coordinates recovery while WALRecoveryController owns its flock().
 * The lock is deliberately retained across scanning, any modal alert, staging,
 * and the final identity-checked rename so another Notational Velocity process
 * cannot recover or replace that journal before it is retired.  Fresh creation
 * still uses O_EXCL.  Confirmed flock contention returns fBsyErr and never enters
 * a recovery workflow.
 *
 * WAL parsing produces every safely recoverable note and says whether the scan
 * was complete.  A complete scan replays those notes into the current database.
 * For an incomplete scan, an epoch-4-or-older database may offer the newest
 * qualifying legacy dot-file.  If the user accepts, that file is copied into
 * place and the WAL prefix is replayed on top.  Without a candidate, a nonempty
 * prefix is replayed into the current database and a warning is shown; an empty
 * prefix instead offers to preserve and skip the failed WAL.
 *
 * Each successful path follows the same durability ordering: prepare a staged
 * controller, durably write any recovered database snapshot while the original
 * WAL is still canonical and locked, rename that WAL to an exclusive UUID name,
 * create and synchronize a fresh WAL, finish format setup/epoch upgrade, and
 * fsync the directory.  Original database/WAL files are retained for partial or
 * legacy recovery.  A complete recovery removes its retired WAL only after the
 * replacement is durable; deletion and its directory sync are best-effort
 * cleanup after that commit.  Legacy/partial failures move newly installed files
 * aside and restore the originals without overwriting another file.  If complete
 * replay already made the current database durable, restoring its old WAL is
 * sufficient because replay is UUID/LSN-idempotent.  Separate-format note-file
 * writes remain pending until this database/WAL transaction has committed.
 *
 * The staged controller intentionally performs no WAL creation, format setup,
 * epoch upgrade, or recursive recovery.  It exists only to validate/load the
 * chosen database and make the pre-retirement snapshot durable; activation is
 * centralized here so every path has the same lock, rollback, and sync rules.
 */

static NSString *NVStartupJournalFilename = @"Interim Note-Changes";

static NSError *NVStartupRecoveryError(int errorNumber, NSString *operation) {
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errorNumber userInfo:
		[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@: %s",
			operation, strerror(errorNumber)] forKey:NSLocalizedDescriptionKey]];
}

static BOOL NVIsLegacyTemporaryDatabaseName(const char *name) {
	if (!name || *name++ != '.') return NO;
	for (NSUInteger group = 0; group < 3; group++) {
		const char *digits = name;
		while (*name >= '0' && *name <= '9') name++;
		if (name == digits) return NO;
		if (group < 2) {
			if (*name != '-') return NO;
			name++;
		} else if (*name != '\0') {
			return NO;
		}
	}
	return YES;
}

static NSComparisonResult NVCompareModificationTimes(struct timespec one, struct timespec two) {
	if (one.tv_sec != two.tv_sec)
		return one.tv_sec < two.tv_sec ? NSOrderedAscending : NSOrderedDescending;
	if (one.tv_nsec != two.tv_nsec)
		return one.tv_nsec < two.tv_nsec ? NSOrderedAscending : NSOrderedDescending;
	return NSOrderedSame;
}

static NSString *NVRecoveryName(NSString *filename, NSString *kind, NSString *identifier) {
	return [NSString stringWithFormat:@"%@ (%@ %@)", filename, kind, identifier];
}

@interface NotationController (StartupRecoveryInitialization)
- (id)_initWithDirectoryURL:(NSURL*)directoryURL recoveredNotes:(NSDictionary*)recoveredNotes
	stagingRecovery:(BOOL)stagingRecovery error:(OSStatus*)error;
@end

@interface NotationController (StartupRecoveryPrivate)
- (NSData*)_legacyTemporaryDatabaseDataReturningName:(NSString**)candidateName
	error:(NSError**)error;
- (NSString*)_installDatabaseData:(NSData*)data recoveryKind:(NSString*)kind
	error:(NSError**)error;
- (BOOL)_rollBackDatabaseRecoveryWithIdentifier:(NSString*)identifier
	recoveryKind:(NSString*)kind error:(NSError**)error;
- (BOOL)_synchronizeRecoveryDirectory:(NSError**)error;
- (BOOL)_renameLockedJournal:(WALRecoveryController*)reader toName:(NSString*)name
	error:(NSError**)error;
- (BOOL)_restoreJournalFromName:(NSString*)backupName error:(NSError**)error;
- (NotationController*)_restartWithRecoveredNotes:(NSDictionary*)recoveredNotes
	lockedJournal:(WALRecoveryController*)reader backupName:(NSString*)backupName
	error:(OSStatus*)error;
- (NotationController*)_restartUsingDatabaseData:(NSData*)data
	recoveredNotes:(NSDictionary*)recoveredNotes recoveryKind:(NSString*)kind
	lockedJournal:(WALRecoveryController*)reader error:(OSStatus*)error;
- (void)_discardStagedController:(NotationController*)controller;
- (NotationController*)_recoverUsingCandidateData:(NSData*)data name:(NSString*)candidateName
	recoveredNotes:(NSDictionary*)recoveredNotes lockedJournal:(WALRecoveryController*)reader
	error:(OSStatus*)error;
- (NotationController*)_recoverCurrentDatabaseWithNotes:(NSDictionary*)recoveredNotes
	lockedJournal:(WALRecoveryController*)reader error:(OSStatus*)error;
- (NotationController*)_startFromOldNotesWithLockedJournal:(WALRecoveryController*)reader
	error:(OSStatus*)error;
- (NotationController*)_finishCompleteWALRecovery:(NSDictionary*)recoveredNotes
	lockedJournal:(WALRecoveryController*)reader error:(OSStatus*)error;
@end

@implementation NotationController (StartupRecovery)

- (NSData*)_legacyTemporaryDatabaseDataReturningName:(NSString**)returnedName
	error:(NSError**)error {
	if ([notationPrefs epochIteration] > 4) return nil;

	/* Inspect through the already-open notes directory and never follow a link:
	 * candidates are untrusted crash leftovers, not user-selected paths. */
	struct stat databaseInfo;
	int databaseError = 0;
	if (fstatat(noteDirectoryFileDescriptor, [NotesDatabaseFileName fileSystemRepresentation],
		&databaseInfo, AT_SYMLINK_NOFOLLOW) < 0)
		databaseError = errno;
	else if (!S_ISREG(databaseInfo.st_mode))
		databaseError = EINVAL;
	if (databaseError) {
		if (error) *error = NVStartupRecoveryError(databaseError,
			@"Inspect database for legacy recovery");
		return nil;
	}

	int scanFD = dup(noteDirectoryFileDescriptor);
	DIR *directory = scanFD >= 0 ? fdopendir(scanFD) : NULL;
	if (!directory) {
		int scanError = errno;
		if (scanFD >= 0) close(scanFD);
		if (error) *error = NVStartupRecoveryError(scanError, @"Scan legacy recovery files");
		return nil;
	}

	/* The filesystem timestamp, including nanoseconds, defines "newest".  The
	 * lexical tie-breaker makes selection deterministic on coarse filesystems. */
	NSString *candidateName = nil;
	struct stat candidateInfo = { 0 };
	int scanError = 0;
	while (1) {
		errno = 0;
		struct dirent *entry = readdir(directory);
		if (!entry) {
			scanError = errno;
			break;
		}
		if (!NVIsLegacyTemporaryDatabaseName(entry->d_name)) continue;
		struct stat info;
		if (fstatat(dirfd(directory), entry->d_name, &info, AT_SYMLINK_NOFOLLOW) < 0 ||
			!S_ISREG(info.st_mode)) continue;
		NSString *name = [NSString stringWithUTF8String:entry->d_name];
		NSComparisonResult timeOrder = candidateName ?
			NVCompareModificationTimes(info.st_mtimespec, candidateInfo.st_mtimespec) :
			NSOrderedDescending;
		if (timeOrder == NSOrderedDescending || (timeOrder == NSOrderedSame &&
			[name compare:candidateName] == NSOrderedDescending)) {
			[candidateName release];
			candidateName = [name copy];
			candidateInfo = info;
		}
	}
	closedir(directory);

	if (scanError) {
		[candidateName release];
		if (error) *error = NVStartupRecoveryError(scanError, @"Scan legacy recovery files");
		return nil;
	}
	if (!candidateName || candidateInfo.st_size <= databaseInfo.st_size ||
		(uint64_t)candidateInfo.st_size > NSUIntegerMax ||
		NVCompareModificationTimes(candidateInfo.st_mtimespec,
			databaseInfo.st_mtimespec) != NSOrderedDescending) {
		[candidateName release];
		return nil;
	}

	/* Re-stat after reading so a candidate changed during the scan/read window is
	 * rejected instead of installing bytes from a different inode or version. */
	NSError *readError = nil;
	NSData *data = [self dataFromNoteNamed:candidateName error:&readError];
	struct stat stableInfo;
	BOOL stable = data && [data length] == (NSUInteger)candidateInfo.st_size &&
		fstatat(noteDirectoryFileDescriptor, [candidateName fileSystemRepresentation],
			&stableInfo, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(stableInfo.st_mode) &&
		stableInfo.st_dev == candidateInfo.st_dev && stableInfo.st_ino == candidateInfo.st_ino &&
		stableInfo.st_size == candidateInfo.st_size &&
		NVCompareModificationTimes(stableInfo.st_mtimespec,
			candidateInfo.st_mtimespec) == NSOrderedSame;
	if (!stable) {
		[candidateName release];
		if (error) *error = readError ?: NVStartupRecoveryError(EAGAIN,
			@"Read stable legacy recovery file");
		return nil;
	}

	if (returnedName) *returnedName = [candidateName autorelease];
	else [candidateName release];
	return data;
}

- (NSModalResponse)_legacyDatabaseRecoveryResponse {
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"Recovery from Interim Note-Changes failed but a newer database file was found; attempt recovery from it instead?", nil)];
	[alert setInformativeText:NSLocalizedString(@"The unrecoverable database will be renamed.", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Recover Database", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Choose another folder", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
	[alert setAlertStyle:NSAlertStyleWarning];
	return [alert runModal];
}

- (NSModalResponse)_failedWALRecoveryResponse {
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"Recovery from Interim Note-Changes failed.", nil)];
	[alert setInformativeText:NSLocalizedString(@"You can start from the older Notes & Settings database instead. The unrecoverable Interim Note-Changes file will be renamed and preserved.", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Start From Old Notes", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Choose another folder", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
	[alert setAlertStyle:NSAlertStyleWarning];
	return [alert runModal];
}

- (void)_showPartialWALRecoveryWarning {
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"Some changes could not be recovered.", nil)];
	[alert setInformativeText:NSLocalizedString(@"Notational Velocity recovered as many notes as possible. The original database and unrecoverable Interim Note-Changes files were renamed and preserved.", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert runModal];
}

- (void)_quitAfterDecliningLegacyDatabaseRecovery {
	[NSApp terminate:nil];
}

- (BOOL)_synchronizeRecoveryDirectory:(NSError**)error {
	if (fsync(noteDirectoryFileDescriptor) == 0) return YES;
	if (error) *error = NVStartupRecoveryError(errno, @"Synchronize recovery directory");
	return NO;
}

- (BOOL)_renameLockedJournal:(WALRecoveryController*)reader toName:(NSString*)name
	error:(NSError**)error {
	/* flock follows the open inode, not its directory name.  Verify that the
	 * locked inode is still the canonical WAL immediately before renaming it. */
	if (!reader || ![reader logFileStillExists]) {
		if (error) *error = NVStartupRecoveryError(EAGAIN,
			@"Verify locked journal before recovery");
		return NO;
	}
	return [self renameNoteFromName:NVStartupJournalFilename toName:name error:error];
}

- (BOOL)_rollBackDatabaseRecoveryWithIdentifier:(NSString*)identifier
	recoveryKind:(NSString*)kind error:(NSError**)error {
	/* Restore the WAL first so a failed database restore never leaves a freshly
	 * created, unrelated journal paired with the preserved original database. */
	BOOL restored = YES;
	NSError *lastError = nil;
	NSString *failedIdentifier = [[NSUUID UUID] UUIDString];
	NSString *journalBackup = NVRecoveryName(NVStartupJournalFilename, kind, identifier);
	if ([self noteExistsWithName:journalBackup] &&
		![self _restoreJournalFromName:journalBackup error:&lastError]) {
		if (error) *error = lastError;
		return NO;
	}

	NSString *databaseBackup = NVRecoveryName(NotesDatabaseFileName, kind, identifier);
	if ([self noteExistsWithName:databaseBackup]) {
		if ([self noteExistsWithName:NotesDatabaseFileName]) {
			NSString *failedName = NVRecoveryName(NotesDatabaseFileName,
				@"failed recovery", failedIdentifier);
			if (![self renameNoteFromName:NotesDatabaseFileName toName:failedName
				error:&lastError])
				restored = NO;
		}
		if (restored && ![self renameNoteFromName:databaseBackup
			toName:NotesDatabaseFileName error:&lastError])
			restored = NO;
	}
	if (![self _synchronizeRecoveryDirectory:&lastError]) restored = NO;
	if (!restored && error) *error = lastError ?: NVStartupRecoveryError(EIO,
		@"Restore startup recovery files");
	return restored;
}

- (BOOL)_restoreJournalFromName:(NSString*)backupName error:(NSError**)error {
	NSError *localError = nil;
	if ([self noteExistsWithName:NVStartupJournalFilename]) {
		/* A failed activation may already have created a canonical WAL.  Lock and
		 * identify it before moving it aside; never rename another live writer. */
		int lockError = 0;
		WALRecoveryController *currentJournal = [[WALRecoveryController alloc]
			initWithDirectoryFileDescriptor:noteDirectoryFileDescriptor
			encryptionKey:[notationPrefs WALSessionKey] error:&lockError journalInUse:NULL];
		if (!currentJournal) {
			if (error) *error = NVStartupRecoveryError(lockError ?: EBUSY,
				@"Lock failed replacement journal for rollback");
			return NO;
		}
		NSString *failedName = NVRecoveryName(NVStartupJournalFilename,
			@"failed startup recovery", [[NSUUID UUID] UUIDString]);
		if (![self _renameLockedJournal:currentJournal toName:failedName
			error:&localError]) {
			[currentJournal release];
			if (error) *error = localError;
			return NO;
		}
		[currentJournal release];
	}
	if (![self renameNoteFromName:backupName toName:NVStartupJournalFilename
		error:&localError] || ![self _synchronizeRecoveryDirectory:&localError]) {
		if (error) *error = localError;
		return NO;
	}
	return YES;
}

- (NSString*)_installDatabaseData:(NSData*)data recoveryKind:(NSString*)kind
	error:(NSError**)error {
	/* Preserve first, create the replacement without overwriting, then commit the
	 * namespace changes with a directory fsync.  The UUID also joins the matching
	 * database and WAL backups for later inspection. */
	NSString *identifier = [[NSUUID UUID] UUIDString];
	NSString *databaseBackup = NVRecoveryName(NotesDatabaseFileName, kind, identifier);
	NSError *localError = nil;

	if (![self renameNoteFromName:NotesDatabaseFileName toName:databaseBackup error:&localError] ||
		![self createDataAtomicallyInNotesDirectory:data withName:NotesDatabaseFileName
			error:&localError] ||
		![self _synchronizeRecoveryDirectory:&localError]) {
		NSError *rollbackError = nil;
		if (![self _rollBackDatabaseRecoveryWithIdentifier:identifier recoveryKind:kind
			error:&rollbackError])
			NSLog(@"Unable to roll back database installation: %@", rollbackError);
		if (error) *error = localError ?: rollbackError;
		return nil;
	}
	return identifier;
}

- (NotationController*)_restartWithRecoveredNotes:(NSDictionary*)recoveredNotes
	lockedJournal:(WALRecoveryController*)reader backupName:(NSString*)backupName
	error:(OSStatus*)error {
	/* Staging validates and snapshots the selected database while the old WAL is
	 * still canonical.  Retire that WAL last, then finish all normal startup work.
	 * The caller owns filesystem rollback because database-replacement recovery
	 * must restore its database and WAL as one transaction. */
	OSStatus restartError = noErr;
	NSError *activationError = nil;
	NotationController *controller = [[[self class] alloc]
		_initWithDirectoryURL:noteDirectoryURL recoveredNotes:recoveredNotes
		stagingRecovery:YES error:&restartError];
	if (!controller) goto failed;
	if (![self _renameLockedJournal:reader toName:backupName error:&activationError])
		goto failed;
	if (![controller initializeJournaling]) {
		activationError = NVStartupRecoveryError(EIO, @"Create replacement journal");
		goto failed;
	}
	[controller databaseSettingsChangedFromOldFormat:
		[controller->notationPrefs notesStorageFormat]];
	NSSet *deferredFileWrites = [[controller->pendingFileWrites copy] autorelease];
	[controller->pendingFileWrites removeAllObjects];
	[controller upgradeDatabaseIfNecessary];
	if (![controller flushAllNoteChanges] || ![controller.walWriter synchronize] ||
		![controller _synchronizeRecoveryDirectory:&activationError])
		goto failed;
	[controller->pendingFileWrites unionSet:deferredFileWrites];
	[controller updateTitlePrefixConnections];
	if ([deferredFileWrites count]) {
		/* This is post-commit: file failures keep their normal retry obligation.
		 * A successful write is followed by a database snapshot of its new metadata. */
		controller->notesChanged = YES;
		(void)[controller flushAllNoteChanges];
	}
	if (error) *error = noErr;
	return controller;

failed:
	if (activationError) NSLog(@"Unable to restart after WAL recovery: %@", activationError);
	[self _discardStagedController:controller];
	if (error) *error = restartError ?: kJournalingError;
	return nil;
}

- (void)_discardStagedController:(NotationController*)controller {
	if (!controller) return;
	/* Format setup can schedule callbacks before a late activation failure.  Make
	 * the rejected controller inert before closing its WAL and releasing it. */
	[NSObject cancelPreviousPerformRequestsWithTarget:controller];
	[NSObject cancelPreviousPerformRequestsWithTarget:
		[ExternalEditingSession sharedExternalEditingSession]
		selector:@selector(initializeDatabase:) object:controller->notationPrefs];
	[controller stopFileNotifications];
	[controller->directoryRetryTimer invalidate];
	controller.directoryRetryTimer = nil;
	[controller->changeWritingTimer invalidate];
	controller.changeWritingTimer = nil;
	/* walWriter has no deferred autorelease ownership, so this synchronously
	 * closes its descriptor before rollback locks the replacement WAL. */
	controller.walWriter = nil;
	[controller release];
}

- (NotationController*)_restartUsingDatabaseData:(NSData*)data
	recoveredNotes:(NSDictionary*)recoveredNotes recoveryKind:(NSString*)kind
	lockedJournal:(WALRecoveryController*)reader error:(OSStatus*)error {
	/* Database-replacement workflows share one paired rollback.  If the WAL
	 * cannot be restored, _rollBackDatabaseRecovery deliberately leaves the
	 * replacement database in place rather than create a mismatched pair. */
	NSError *transactionError = nil;
	NSString *identifier = [self _installDatabaseData:data recoveryKind:kind
		error:&transactionError];
	if (!identifier) {
		NSLog(@"Unable to install recovery database: %@", transactionError);
		return nil;
	}
	NSString *journalBackup = NVRecoveryName(NVStartupJournalFilename, kind, identifier);
	NotationController *replacement = [self _restartWithRecoveredNotes:recoveredNotes
		lockedJournal:reader backupName:journalBackup error:error];
	if (replacement) return replacement;

	NSError *rollbackError = nil;
	if (![self _rollBackDatabaseRecoveryWithIdentifier:identifier recoveryKind:kind
		error:&rollbackError])
		NSLog(@"Unable to roll back %@: %@", kind, rollbackError);
	return nil;
}

- (NotationController*)_recoverUsingCandidateData:(NSData*)data name:(NSString*)candidateName
	recoveredNotes:(NSDictionary*)recoveredNotes lockedJournal:(WALRecoveryController*)reader
	error:(OSStatus*)error {
	/* The prompt precedes every mutation.  Installation preserves the stale
	 * database; staging then replays the WAL prefix into the copied candidate. */
	NSModalResponse response = [self _legacyDatabaseRecoveryResponse];
	if (response == NSAlertSecondButtonReturn) {
		if (error) *error = kPassCanceledErr;
		return nil;
	}
	if (response != NSAlertFirstButtonReturn) {
		[self _quitAfterDecliningLegacyDatabaseRecovery];
		return nil;
	}

	NSString *kind = @"legacy recovery";
	NotationController *replacement = [self _restartUsingDatabaseData:data
		recoveredNotes:(recoveredNotes ?: [NSDictionary dictionary]) recoveryKind:kind
		lockedJournal:reader error:error];
	if (replacement)
		NSLog(@"Recovered legacy database from '%@'", candidateName);
	return replacement;
}

- (NotationController*)_recoverCurrentDatabaseWithNotes:(NSDictionary*)recoveredNotes
	lockedJournal:(WALRecoveryController*)reader error:(OSStatus*)error {
	/* Install an identical copy so the original database becomes the immutable
	 * pre-merge backup before recovered notes are applied to the canonical copy. */
	NSError *readError = nil;
	NSData *databaseData = [self dataFromNoteNamed:NotesDatabaseFileName error:&readError];
	if (!databaseData) {
		NSLog(@"Unable to read database for partial WAL recovery: %@", readError);
		return nil;
	}
	NotationController *replacement = [self _restartUsingDatabaseData:databaseData
		recoveredNotes:recoveredNotes recoveryKind:@"partial recovery"
		lockedJournal:reader error:error];
	if (replacement)
		[replacement _showPartialWALRecoveryWarning];
	return replacement;
}

- (NotationController*)_startFromOldNotesWithLockedJournal:(WALRecoveryController*)reader
	error:(OSStatus*)error {
	/* Validate that the old database can initialize before moving its failed WAL.
	 * No database backup is needed because this path does not replace it. */
	NSModalResponse response = [self _failedWALRecoveryResponse];
	if (response == NSAlertSecondButtonReturn) {
		if (error) *error = kPassCanceledErr;
		return nil;
	}
	if (response != NSAlertFirstButtonReturn) {
		[self _quitAfterDecliningLegacyDatabaseRecovery];
		return nil;
	}

	NSString *backupName = NVRecoveryName(NVStartupJournalFilename,
		@"failed recovery", [[NSUUID UUID] UUIDString]);
	NotationController *replacement = [self _restartWithRecoveredNotes:nil
		lockedJournal:reader backupName:backupName error:error];
	if (replacement) return replacement;
	NSError *restoreError = nil;
	if ([self noteExistsWithName:backupName] &&
		![self _restoreJournalFromName:backupName error:&restoreError])
		NSLog(@"Unable to restore failed WAL after restart failure: %@", restoreError);
	return nil;
}

- (NotationController*)_finishCompleteWALRecovery:(NSDictionary*)recoveredNotes
	lockedJournal:(WALRecoveryController*)reader error:(OSStatus*)error {
	/* A complete scan needs no permanent recovery backups.  The temporary WAL
	 * rename still makes rollback possible until the fresh journal is durable. */
	NSString *backupName = NVRecoveryName(NVStartupJournalFilename,
		@"WAL recovery", [[NSUUID UUID] UUIDString]);
	NotationController *replacement = [self _restartWithRecoveredNotes:
		([recoveredNotes count] ? recoveredNotes : nil) lockedJournal:reader
		backupName:backupName error:error];
	if (replacement) {
		if (unlinkat(noteDirectoryFileDescriptor, [backupName fileSystemRepresentation], 0) < 0) {
			NSLog(@"Unable to remove retired WAL '%@': %s", backupName, strerror(errno));
		} else {
			NSError *syncError = nil;
			if (![self _synchronizeRecoveryDirectory:&syncError])
				NSLog(@"Unable to synchronize retired WAL removal: %@", syncError);
		}
		return replacement;
	}
	NSError *restoreError = nil;
	if ([self noteExistsWithName:backupName] &&
		![self _restoreJournalFromName:backupName error:&restoreError])
		NSLog(@"Unable to restore WAL after recovery restart failure: %@", restoreError);
	return nil;
}

- (NotationController*)newControllerByRecoveringStartupJournal:(OSStatus*)error {
	if (error) *error = kJournalingError;
	/* reader stays retained through every branch below.  Releasing it earlier
	 * would release flock() while a modal or file transaction is in progress. */
	int readerError = 0;
	BOOL journalInUse = NO;
	WALRecoveryController *reader = [[WALRecoveryController alloc]
		initWithDirectoryFileDescriptor:noteDirectoryFileDescriptor
		encryptionKey:[notationPrefs WALSessionKey] error:&readerError
		journalInUse:&journalInUse];
	if (!reader) {
		if (journalInUse) {
			if (error) *error = fBsyErr;
		}
		return nil;
	}

	/* Complete recovery has no user choice.  Incomplete recovery is routed only
	 * after retaining the valid prefix returned by the WAL parser. */
	NotationController *replacement = nil;
	BOOL incomplete = YES;
	NSDictionary *recoveredNotes = [[reader
		recoveredNotesWithIncompleteRecovery:&incomplete] retain];
	if (!incomplete) {
		replacement = [self _finishCompleteWALRecovery:recoveredNotes
			lockedJournal:reader error:error];
	} else {
		/* Candidate discovery happens only after an incomplete scan and before any
		 * canonical file is modified. */
		NSError *candidateError = nil;
		NSString *candidateName = nil;
		NSData *candidateData = [self _legacyTemporaryDatabaseDataReturningName:
			&candidateName error:&candidateError];
		if (candidateError)
			NSLog(@"Unable to inspect legacy temporary databases: %@", candidateError);
		if (candidateData) {
			replacement = [self _recoverUsingCandidateData:candidateData
				name:candidateName recoveredNotes:recoveredNotes lockedJournal:reader
				error:error];
		} else if (!candidateError || [recoveredNotes count]) {
			replacement = [recoveredNotes count] ?
				[self _recoverCurrentDatabaseWithNotes:recoveredNotes
					lockedJournal:reader error:error] :
				[self _startFromOldNotesWithLockedJournal:reader error:error];
		}
	}
	[reader release];
	[recoveredNotes release];
	return replacement;
}

@end
