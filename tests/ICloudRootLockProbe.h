/* Included by ICloudAPIContractTest.m to reuse its coordination/process helpers.
 * Synthetic lock files/directories only. No NV store, WAL, or version history is modified.
 * Exit 0: completed observation/control; 1: hazard/control failure;
 * 2: inconclusive/invalid setup; 124: hard deadline (including blocked open).
 */
#include <sys/file.h>
#include <math.h>

static const char *RootLockName = ".nv-root.lock";

static void RootLockDeadline(int signalNumber) {
	(void)signalNumber;
	static const char message[] = "INCONCLUSIVE AV-LOCK hard-deadline; last BEGIN identifies unfinished phase\n";
	(void)write(STDERR_FILENO, message, sizeof(message) - 1);
	_exit(124);
}

static BOOL RootLockSameFile(struct stat a, struct stat b) {
	return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

static NSURL *RootLockSession(NSURL *root, NSString *identifier) {
	NSUUID *uuid = [[[NSUUID alloc] initWithUUIDString:identifier] autorelease];
	if (!uuid || ![[uuid UUIDString] isEqualToString:identifier]) return nil;
	return [root URLByAppendingPathComponent:[@"nv-api-contract-lock-" stringByAppendingString:identifier]
		isDirectory:YES];
}

static BOOL RootLockValidate(NSURL *session, NSString *identifier) {
	struct stat st;
	if (!session || lstat([session fileSystemRepresentation], &st) || !S_ISDIR(st.st_mode)) return NO;
	NSURL *marker = [session URLByAppendingPathComponent:@"probe-owner.txt"];
	NSData *expected = [[@"NV root-lock probe v1\n" stringByAppendingString:identifier]
		dataUsingEncoding:NSUTF8StringEncoding];
	return [CoordinatedRead(marker, NULL) isEqual:expected];
}

static int RootLockDirectory(NSURL *url) {
	return open([url fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

/* Deliberately the proposed descriptor-relative startup algorithm, not a long
 * coordinated accessor pretending to provide cross-process exclusion. O_NONBLOCK
 * protects the FIFO case, but is NOT assumed to bound provider materialization. */
static int RootLockOpen(int directory, BOOL create, BOOL exclusive, int *outError) {
	Report(@"BEGIN", @"AV-LOCK-open", create ? @"create-if-needed" : @"existing-only");
	NSTimeInterval started = [[NSProcessInfo processInfo] systemUptime];
	int fd = openat(directory, RootLockName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK |
		(create ? O_CREAT : 0) | (exclusive ? O_EXCL : 0), 0600);
	int saved = fd < 0 ? errno : 0;
	struct stat st;
	if (fd >= 0 && (fstat(fd, &st) || !S_ISREG(st.st_mode))) {
		saved = EINVAL;
		close(fd);
		fd = -1;
	}
	Report(@"OBSERVE", @"AV-LOCK-open", [NSString stringWithFormat:@"seconds=%.3f errno=%d",
		[[NSProcessInfo processInfo] systemUptime] - started, saved]);
	if (outError) *outError = saved;
	return fd;
}

/* The parent never passes its descriptor to the exec'ed contender (CLOEXEC).
 * 0 means this independent process acquired the pathname's lock, 3 contention,
 * 4 unsafe/unavailable file. No create: observing absence must not repair it. */
static int RootLockContender(NSURL *directoryURL) {
	int directory = RootLockDirectory(directoryURL), error = 0;
	struct stat rootStat;
	if (directory >= 0 && fstat(directory, &rootStat) == 0)
		Report(@"OBSERVE", @"AV-LOCK-contender-root", [NSString stringWithFormat:
			@"dev=%llu ino=%llu", (unsigned long long)rootStat.st_dev, rootStat.st_ino]);
	int fd = directory < 0 ? -1 : RootLockOpen(directory, NO, NO, &error);
	if (directory >= 0) close(directory);
	if (fd < 0) return 4;
	int result = flock(fd, LOCK_EX | LOCK_NB);
	error = result == 0 ? 0 : errno;
	struct stat st;
	BOOL observed = fstat(fd, &st) == 0;
	Report(@"OBSERVE", @"AV-LOCK-contender", [NSString stringWithFormat:
		@"acquired=%d errno=%d dev=%llu ino=%llu", result == 0, error,
		observed ? (unsigned long long)st.st_dev : 0, observed ? st.st_ino : 0]);
	close(fd);
	return result == 0 ? 0 : ((error == EWOULDBLOCK || error == EAGAIN) ? 3 : 4);
}

static int RootLockTryCommand(NSArray *arguments) {
	NSTask *child = LaunchChild(arguments);
	if (!child) return 4;
	if (!WaitFor(5.0, ^BOOL{ return ![child isRunning]; })) {
		kill([child processIdentifier], SIGKILL);
		[child waitUntilExit];
		Report(@"INCONCLUSIVE", @"AV-LOCK-contender", @"five-second deadline");
		return 124;
	}
	return [child terminationReason] == NSTaskTerminationReasonExit ? [child terminationStatus] : 124;
}

static int RootLockTryChild(NSURL *directoryURL) {
	return RootLockTryCommand(@[@"root-lock-contender", [directoryURL path]]);
}

static int RootDirectoryContender(NSURL *url, BOOL hold) {
	int fd = RootLockDirectory(url);
	if (fd < 0) return 4;
	int result = flock(fd, LOCK_EX | LOCK_NB), saved = result == 0 ? 0 : errno;
	if (result == 0 && hold) {
		// One pipe write is the readiness handshake; no provider marker or timeout
		// is treated as evidence that the lock was acquired. Parent kills this child.
		(void)write(STDOUT_FILENO, "READY\n", 6);
		for (;;) pause(); // process alarm bounds orphaned holders
	}
	Report(@"OBSERVE", @"AV-LOCK-directory-contender", [NSString stringWithFormat:
		@"acquired=%d errno=%d", result == 0, saved]);
	close(fd);
	return result == 0 ? 0 : ((saved == EWOULDBLOCK || saved == EAGAIN) ? 3 : 4);
}

static BOOL RootDirectoryExcluded(int fd, NSURL *url, NSString *phase) {
	struct stat held, current;
	BOOL same = fstat(fd, &held) == 0 && lstat([url fileSystemRepresentation], &current) == 0 &&
		RootLockSameFile(held, current);
	int contender = RootLockTryCommand(@[@"root-lock-directory-contender", [url path]]);
	BOOL good = same && contender == 3;
	Report(good ? @"PASS" : @"FAIL", @"AV-LOCK-directory", [NSString stringWithFormat:
		@"phase=%@ same-inode=%d contender-status=%d", phase, same, contender]);
	return good;
}

static BOOL RootDirectoryIsDataless(NSURL *url) {
	struct stat st;
	return lstat([url fileSystemRepresentation], &st) == 0 && (st.st_flags & SF_DATALESS) != 0;
}

static int RootDirectoryControl(NSURL *root, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *session = [root URLByAppendingPathComponent:[@"nv-api-contract-directory-lock-"
		stringByAppendingString:[[NSUUID UUID] UUIDString]] isDirectory:YES];
	NSURL *original = [session URLByAppendingPathComponent:@"original" isDirectory:YES];
	NSURL *container = [session URLByAppendingPathComponent:@"container" isDirectory:YES];
	NSError *error = nil;
	if (!CoordinatedCreateDirectory(session, &error) || !CoordinatedCreateDirectory(original, &error) ||
		!CoordinatedCreateDirectory(container, &error)) {
		ReportError(@"INCONCLUSIVE", @"AV-LOCK-directory-prepare", error);
		return 2;
	}
	Report(@"OBSERVE", @"AV-LOCK-directory-session", [session lastPathComponent]);
	int fd = RootLockDirectory(original);
	if (fd < 0) return 2;
	int locked = flock(fd, LOCK_EX | LOCK_NB), saved = locked == 0 ? 0 : errno;
	Report(locked == 0 ? @"PASS" : @"INCONCLUSIVE", @"AV-LOCK-directory-acquire",
		[NSString stringWithFormat:@"O_RDONLY directory errno=%d", saved]);
	if (locked != 0) { close(fd); return 2; }
	BOOL ok = RootDirectoryExcluded(fd, original, @"initial");
	// Catalog scans open a separate descriptor: closing it must not unlock fd.
	int scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (scan >= 0) close(scan);
	ok &= scan >= 0 && RootDirectoryExcluded(fd, original, @"after-independent-scan-close");
	NSURL *payloadURL = [original URLByAppendingPathComponent:@"payload.txt"];
	NSData *payload = PatternData(32768, 19);
	BOOL wrote = CoordinatedWrite(payloadURL, [NSData data], &error) &&
		CoordinatedSafeReplace(payloadURL, payload, &error) != nil;
	ok &= wrote && RootDirectoryExcluded(fd, original, @"coordinated-child-create-replace");
	NSURL *renamed = [session URLByAppendingPathComponent:@"renamed" isDirectory:YES];
	NSURL *moved = [container URLByAppendingPathComponent:@"moved" isDirectory:YES];
	BOOL renamedOK = CoordinatedMove(original, renamed, &error);
	ok &= renamedOK && RootDirectoryExcluded(fd, renamed, @"rename");
	BOOL movedOK = renamedOK && CoordinatedMove(renamed, moved, &error);
	ok &= movedOK && RootDirectoryExcluded(fd, moved, @"move-to-another-parent");
	if (!wrote || !movedOK) {
		ReportError(@"FAIL", @"AV-LOCK-directory-setup-mutation", error);
		close(fd);
		return 1;
	}
	// Different directory at the old pathname is deliberately NOT the same root.
	BOOL recreated = CoordinatedCreateDirectory(original, &error);
	struct stat heldStat, newStat;
	BOOL different = recreated && fstat(fd, &heldStat) == 0 &&
		lstat([original fileSystemRepresentation], &newStat) == 0 && !RootLockSameFile(heldStat, newStat);
	BOOL independent = different && RootLockTryCommand(@[@"root-lock-directory-contender", [original path]]) == 0;
	Report(independent ? @"PASS" : @"FAIL", @"AV-LOCK-directory-old-path-recreated",
		@"distinct directory is independently lockable; root-identity fencing is still required");
	ok &= independent;
	int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
	if (duplicate < 0) { close(fd); return 1; }
	close(fd);
	fd = duplicate;
	ok &= RootDirectoryExcluded(fd, moved, @"duplicate-handoff-original-closed");
	close(fd);
	BOOL released = RootLockTryCommand(@[@"root-lock-directory-contender", [moved path]]) == 0;
	Report(released ? @"PASS" : @"FAIL", @"AV-LOCK-directory-release", @"last descriptor closed");
	ok &= released;

	// A killed process must release the directory lock. Its descriptor cannot
	// escape via inheritance; child and tester each open independently.
	NSTask *holder = [[[NSTask alloc] init] autorelease];
	NSPipe *ready = [NSPipe pipe];
	[holder setExecutableURL:[NSURL fileURLWithPath:[[NSBundle mainBundle] executablePath]]];
	[holder setArguments:@[@"root-lock-directory-holder", [moved path]]];
	[holder setStandardOutput:ready];
	BOOL launched = [holder launchAndReturnError:&error];
	NSData *handshake = launched ? [[ready fileHandleForReading] readDataOfLength:6] : nil;
	BOOL confirmed = [handshake isEqual:[@"READY\n" dataUsingEncoding:NSUTF8StringEncoding]] && [holder isRunning];
	BOOL excluded = confirmed && RootLockTryCommand(@[@"root-lock-directory-contender", [moved path]]) == 3;
	BOOL killed = NO;
	if (launched) {
		if ([holder isRunning]) killed = kill([holder processIdentifier], SIGKILL) == 0;
		[holder waitUntilExit];
	}
	BOOL crashRelease = excluded && killed && [holder terminationReason] == NSTaskTerminationReasonUncaughtSignal &&
		[holder terminationStatus] == SIGKILL &&
		RootLockTryCommand(@[@"root-lock-directory-contender", [moved path]]) == 0;
	Report(crashRelease ? @"PASS" : @"FAIL", @"AV-LOCK-directory-crash-release",
		@"pipe-confirmed independent holder killed, then independently reacquired");
	ok &= crashRelease;

	payloadURL = [moved URLByAppendingPathComponent:@"payload.txt"];
	if (![manager isUbiquitousItemAtURL:moved]) {
		Report(@"SKIP", @"AV-LOCK-directory-eviction", @"no positive ubiquitous-item evidence");
		return ok ? 0 : 1;
	}
	if (!WaitUntilUploaded(payloadURL, MIN(timeout, 30))) {
		Report(@"INCONCLUSIVE", @"AV-LOCK-directory-eviction", @"payload not positively uploaded");
		return ok ? 2 : 1;
	}
	Report(@"BEGIN", @"AV-LOCK-directory-eviction", @"no holder; require directory SF_DATALESS, not merely an evicted child");
	BOOL requested = [manager evictUbiquitousItemAtURL:moved error:&error];
	BOOL dataless = requested && WaitFor(MIN(timeout, 15), ^BOOL{ return RootDirectoryIsDataless(moved); });
	BOOL fullDirectoryEvicted = dataless;
	BOOL childEvicted = IsDownloadStatus(payloadURL, NSURLUbiquitousItemDownloadingStatusNotDownloaded);
	Report(dataless ? @"OBSERVE" : @"INCONCLUSIVE", @"AV-LOCK-directory-eviction",
		[NSString stringWithFormat:@"requested=%d directory-dataless=%d child-not-downloaded=%d error=%@",
			requested, dataless, childEvicted, ErrorCode(error)]);
	// Child-only eviction still permits a useful locked-directory rematerialization
	// check, but never satisfies the stronger directory-placeholder prerequisite.
	if (!dataless && !childEvicted) return ok ? 2 : 1;
	NSTimeInterval started = [[NSProcessInfo processInfo] systemUptime];
	Report(@"BEGIN", @"AV-LOCK-directory-cold-open", dataless ? @"opening positively dataless directory" :
		@"opening directory with evicted child ONLY; directory placeholder not established");
	fd = RootLockDirectory(moved);
	locked = fd < 0 ? -1 : flock(fd, LOCK_EX | LOCK_NB);
	saved = locked == 0 ? 0 : errno;
	Report(locked == 0 ? @"OBSERVE" : @"INCONCLUSIVE", @"AV-LOCK-directory-cold-open",
		[NSString stringWithFormat:@"seconds=%.3f errno=%d remains-dataless=%d",
			[[NSProcessInfo processInfo] systemUptime] - started, saved, RootDirectoryIsDataless(moved)]);
	if (locked != 0) { if (fd >= 0) close(fd); return ok ? 2 : 1; }
	ok &= RootDirectoryExcluded(fd, moved, dataless ? @"after-dataless-open" : @"after-child-only-eviction");
	BOOL materialized = [CoordinatedRead(payloadURL, &error) isEqual:payload];
	Report(materialized ? @"PASS" : @"FAIL", @"AV-LOCK-directory-materialize", @"exact child payload read while directory locked");
	ok &= materialized && RootDirectoryExcluded(fd, moved, @"after-materialization");
	error = nil;
	requested = [manager evictUbiquitousItemAtURL:moved error:&error];
	dataless = requested && WaitFor(MIN(timeout, 15), ^BOOL{ return RootDirectoryIsDataless(moved); });
	childEvicted = IsDownloadStatus(payloadURL, NSURLUbiquitousItemDownloadingStatusNotDownloaded);
	Report(dataless ? @"OBSERVE" : @"INCONCLUSIVE", @"AV-LOCK-directory-evict-while-held",
		[NSString stringWithFormat:@"requested=%d directory-dataless=%d child-not-downloaded=%d error=%@",
			requested, dataless, childEvicted, ErrorCode(error)]);
	ok &= RootDirectoryExcluded(fd, moved, @"after-held-eviction-attempt");
	if (dataless || childEvicted) {
		BOOL exact = [CoordinatedRead(payloadURL, &error) isEqual:payload];
		Report(exact ? @"PASS" : @"FAIL", @"AV-LOCK-directory-rematerialize", @"exact child payload after held eviction");
		ok &= exact;
		ok &= RootDirectoryExcluded(fd, moved, @"after-held-rematerialization");
	}
	close(fd);
	return ok ? (fullDirectoryEvicted ? 0 : 2) : 1;
}

static BOOL RootLockSnapshot(int directory, int held, NSString *phase) {
	struct stat original, named;
	BOOL haveOriginal = fstat(held, &original) == 0;
	BOOL haveName = fstatat(directory, RootLockName, &named, AT_SYMLINK_NOFOLLOW) == 0;
	int nameError = haveName ? 0 : errno;
	BOOL same = haveOriginal && haveName && RootLockSameFile(original, named);
	Report(@"OBSERVE", @"AV-LOCK-identity", [NSString stringWithFormat:
		@"phase=%@ held-valid=%d held-ino=%llu held-links=%u name-errno=%d name-ino=%llu same=%d mode=%o dataless=%d",
		phase, haveOriginal, haveOriginal ? original.st_ino : 0,
		haveOriginal ? original.st_nlink : 0, nameError, haveName ? named.st_ino : 0, same,
		haveName ? named.st_mode & 0777 : 0, haveName && (named.st_flags & SF_DATALESS) != 0]);
	return same;
}

static void RootLockInspect(NSURL *directoryURL) {
	NSURL *url = [directoryURL URLByAppendingPathComponent:@".nv-root.lock"];
	Report(@"BEGIN", @"AV-LOCK-inspect", @"advisory metadata and unresolved count only");
	NSError *error = nil;
	id ubiquitous = ResourceValue(url, NSURLIsUbiquitousItemKey, &error);
	id status = ResourceValue(url, NSURLUbiquitousItemDownloadingStatusKey, &error);
	id uploaded = ResourceValue(url, NSURLUbiquitousItemIsUploadedKey, &error);
	Report(@"OBSERVE", @"AV-LOCK-status", [NSString stringWithFormat:
		@"ubiquitous=%@ download=%@ uploaded=%@ error=%@", ubiquitous ?: @"unknown",
		status ?: @"unknown", uploaded ?: @"unknown", ErrorCode(error)]);
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	[coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly
		error:&error byAccessor:^(NSURL *newURL) {
		NSArray *versions = [NSFileVersion unresolvedConflictVersionsOfItemAtURL:newURL];
		Report(@"OBSERVE", @"AV-LOCK-versions", versions ? [NSString stringWithFormat:
			@"unresolved=%lu", (unsigned long)[versions count]] : @"unresolved=unknown (nil)");
	}];
	if (error) ReportError(@"INCONCLUSIVE", @"AV-LOCK-inspect", error);
	NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[directoryURL path] error:NULL];
	Report(@"OBSERVE", @"AV-LOCK-namespace", names ? [NSString stringWithFormat:
		@"children=%lu (extra conflict names are not automatically resolved)", (unsigned long)[names count]] :
		@"children=unknown");
}

static BOOL RootLockPrepare(NSURL *root, NSString *identifier) {
	NSURL *session = RootLockSession(root, identifier);
	NSError *error = nil;
	if (!session || !CoordinatedCreateDirectory(session, &error)) {
		ReportError(@"INCONCLUSIVE", @"AV-LOCK-prepare-exclusive", error);
		return NO;
	}
	NSData *owner = [[@"NV root-lock probe v1\n" stringByAppendingString:identifier]
		dataUsingEncoding:NSUTF8StringEncoding];
	if (!CoordinatedWriteWithOptions([session URLByAppendingPathComponent:@"probe-owner.txt"], owner,
		0, NSDataWritingWithoutOverwriting, &error)) return NO;
	for (NSString *slot in @[@"cold", @"held", @"race"]) {
		NSURL *directoryURL = [session URLByAppendingPathComponent:slot isDirectory:YES];
		if (!CoordinatedCreateDirectory(directoryURL, &error)) return NO;
		if ([slot isEqualToString:@"race"]) continue; // each Mac must prove local exclusive creation
		int directory = RootLockDirectory(directoryURL), openError = 0;
		int fd = directory < 0 ? -1 : RootLockOpen(directory, YES, YES, &openError);
		BOOL seeded = fd >= 0 && fsync(fd) == 0;
		if (fd >= 0) close(fd);
		if (directory >= 0) close(directory);
		if (!seeded) return NO;
	}
	Report(@"OBSERVE", @"AV-LOCK-prepared", [NSString stringWithFormat:
		@"run=%@ cold/held contain empty locks; race has no lock; retain this test-owned subtree", identifier]);
	return YES;
}

static int RootLockWatch(NSURL *directoryURL, BOOL race, NSTimeInterval start, NSTimeInterval duration) {
	if (!isfinite(start) || (race && start <= 0)) return 2;
	int directory = RootLockDirectory(directoryURL);
	if (directory < 0) return 2;
	struct stat rootStat;
	if (fstat(directory, &rootStat) != 0) { close(directory); return 2; }
	if (race) {
		struct stat st;
		if (fstatat(directory, RootLockName, &st, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
			close(directory);
			Report(@"INCONCLUSIVE", @"AV-LOCK-race", @"lock must be absent before scheduled start");
			return 2;
		}
	}
	if (start > 0) {
		NSTimeInterval delay = start - [[NSDate date] timeIntervalSince1970];
		if (delay < 0 || delay > 60) { close(directory); return 2; }
		Report(@"OBSERVE", @"AV-LOCK-ready", @"waiting for scheduled start; clocks are not a provider fence");
		WaitFor(delay + 0.1, ^BOOL{ return [[NSDate date] timeIntervalSince1970] >= start; });
	}
	struct stat before;
	BOOL haveBefore = fstatat(directory, RootLockName, &before, AT_SYMLINK_NOFOLLOW) == 0;
	Report(@"OBSERVE", @"AV-LOCK-before-open", [NSString stringWithFormat:
		@"exists=%d dataless=%d", haveBefore, haveBefore && (before.st_flags & SF_DATALESS) != 0]);
	int openError = 0;
	int held = RootLockOpen(directory, YES, race, &openError);
	if (held < 0 || flock(held, LOCK_EX | LOCK_NB) != 0) {
		if (held >= 0) close(held);
		close(directory);
		Report(@"INCONCLUSIVE", @"AV-LOCK-holder", @"open/lock failed; no unlocked writer admitted");
		return 2;
	}
	if (race && fsync(held) != 0) { close(held); close(directory); return 2; }
	Report(@"OBSERVE", @"AV-LOCK-holder", [NSString stringWithFormat:
		@"acquired=1 exclusive-created=%d epoch=%.3f pid=%d root-dev=%llu root-ino=%llu", race,
		[[NSDate date] timeIntervalSince1970], getpid(), (unsigned long long)rootStat.st_dev, rootStat.st_ino]);
	BOOL hazard = NO, uncertain = NO, changed = NO;
	NSUInteger attempts = 0;
	NSTimeInterval deadline = [[NSProcessInfo processInfo] systemUptime] + duration;
	do {
		changed |= !RootLockSnapshot(directory, held, @"held");
		int contender = RootLockTryChild(directoryURL);
		attempts++;
		struct stat currentRoot;
		if (lstat([directoryURL fileSystemRepresentation], &currentRoot) != 0 ||
			!RootLockSameFile(rootStat, currentRoot)) {
			uncertain = YES;
			Report(@"INCONCLUSIVE", @"AV-LOCK-root", @"root itself changed; do not attribute this to lock replacement");
			break;
		}
		if (contender == 0) {
			hazard = YES;
			Report(@"HAZARD", @"AV-LOCK-local-exclusion", @"second local process acquired while original descriptor remains locked");
			RootLockSnapshot(directory, held, @"after-second-acquisition");
			break;
		}
		if (contender != 3) uncertain = YES;
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
	} while ([[NSProcessInfo processInfo] systemUptime] < deadline);
	RootLockInspect(directoryURL); // may be slow: keep holding throughout, bounded by watchdog
	close(held);
	close(directory);
	Report(@"OBSERVE", @"AV-LOCK-watch-end", [NSString stringWithFormat:
		@"epoch=%.3f attempts=%lu name-changed=%d hazard=%d inconclusive-attempt=%d; no global stability claim",
		[[NSDate date] timeIntervalSince1970], (unsigned long)attempts, changed, hazard, uncertain]);
	return hazard ? 1 : (uncertain ? 2 : 0);
}

static int RootLockControl(NSURL *root) {
	NSString *identifier = [[NSUUID UUID] UUIDString];
	if (!RootLockPrepare(root, identifier)) return 2;
	NSURL *session = RootLockSession(root, identifier);
	NSURL *directoryURL = [session URLByAppendingPathComponent:@"held" isDirectory:YES];
	NSURL *url = [directoryURL URLByAppendingPathComponent:@".nv-root.lock"];
	int directory = RootLockDirectory(directoryURL), openError = 0;
	int held = directory < 0 ? -1 : RootLockOpen(directory, NO, NO, &openError);
	if (held < 0 || flock(held, LOCK_EX | LOCK_NB) != 0) {
		if (held >= 0) close(held);
		if (directory >= 0) close(directory);
		return 2;
	}
	BOOL ok = RootLockTryChild(directoryURL) == 3;
	Report(ok ? @"PASS" : @"FAIL", @"AV-LOCK-control-contention", @"independent process must be rejected");
	close(held);
	BOOL afterRelease = RootLockTryChild(directoryURL) == 0;
	ok &= afterRelease;
	Report(afterRelease ? @"PASS" : @"FAIL", @"AV-LOCK-control-release", @"unchanged file becomes lockable after holder closes");
	held = RootLockOpen(directory, NO, NO, &openError);
	if (held < 0 || flock(held, LOCK_EX | LOCK_NB) != 0) {
		if (held >= 0) close(held);
		close(directory);
		return 1;
	}
	NSError *error = nil;
	BOOL replaced = CoordinatedSafeReplace(url, [NSData data], &error) != nil;
	BOOL changed = !RootLockSnapshot(directory, held, @"forced-same-byte-replacement");
	BOOL reproduced = replaced && changed && RootLockTryChild(directoryURL) == 0;
	Report(reproduced ? @"PASS" : @"FAIL", @"AV-LOCK-control-replacement",
		@"positive control: deliberate same-byte Foundation replacement permits a second local lock; not provider evidence");
	ok &= reproduced;
	close(held);
	// Deliberate destructive control is restricted to the just-created private subtree.
	held = RootLockOpen(directory, NO, NO, &openError);
	BOOL locked = held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0;
	BOOL removed = locked && unlinkat(directory, RootLockName, 0) == 0;
	int replacement = removed ? RootLockOpen(directory, YES, YES, &openError) : -1;
	if (replacement >= 0) close(replacement);
	reproduced = removed && replacement >= 0 && !RootLockSnapshot(directory, held, @"forced-unlink-recreate") &&
		RootLockTryChild(directoryURL) == 0;
	Report(reproduced ? @"PASS" : @"FAIL", @"AV-LOCK-control-unlink-recreate",
		@"positive control: original locked descriptor does not protect a recreated pathname");
	ok &= reproduced;
	if (held >= 0) close(held);
	close(directory);
	// Refuse unsafe lock-file types rather than following or blocking on them.
	directoryURL = [session URLByAppendingPathComponent:@"race" isDirectory:YES];
	directory = RootLockDirectory(directoryURL);
	BOOL symlinkRejected = directory >= 0 && symlinkat("../probe-owner.txt", directory, RootLockName) == 0 &&
		RootLockTryChild(directoryURL) == 4;
	ok &= symlinkRejected;
	Report(symlinkRejected ? @"PASS" : @"FAIL", @"AV-LOCK-control-symlink", @"must reject without following");
	BOOL fifoRejected = symlinkRejected && unlinkat(directory, RootLockName, 0) == 0 &&
		mkfifo([[directoryURL URLByAppendingPathComponent:@".nv-root.lock"] fileSystemRepresentation], 0600) == 0 &&
		RootLockTryChild(directoryURL) == 4;
	ok &= fifoRejected;
	Report(fifoRejected ? @"PASS" : @"FAIL", @"AV-LOCK-control-fifo", @"must reject without blocking");
	if (directory >= 0) close(directory);
	return ok ? 0 : 1;
}

static int RunRootLockProbe(NSString *mode, NSURL *root, int argc, const char **argv,
	NSTimeInterval requestedTimeout) {
	// A process deadline bounds synchronous Foundation calls AND raw open().
	NSTimeInterval duration = MIN(MAX(requestedTimeout, 1.0), 300.0);
	if (!isfinite(duration)) duration = 30.0;
	signal(SIGALRM, RootLockDeadline);
	alarm((unsigned int)ceil(duration + 70.0)); // scheduled start <=60s, then bounded watch
	if ([mode isEqualToString:@"root-lock-directory-contender"] ||
		[mode isEqualToString:@"root-lock-directory-holder"]) {
		BOOL hold = [mode isEqualToString:@"root-lock-directory-holder"];
		alarm(hold ? 10 : 5);
		return RootDirectoryContender(root, hold);
	}
	if ([mode isEqualToString:@"root-lock-directory"]) return RootDirectoryControl(root, duration);
	if ([mode isEqualToString:@"root-lock-contender"]) {
		alarm(5);
		return RootLockContender(root);
	}
	if ([mode isEqualToString:@"root-lock-control"]) return RootLockControl(root);
	if (argc < 4) return 2;
	NSString *identifier = [NSString stringWithUTF8String:argv[3]];
	NSURL *session = RootLockSession(root, identifier);
	if ([mode isEqualToString:@"root-lock-prepare"]) return RootLockPrepare(root, identifier) ? 0 : 2;
	if (!RootLockValidate(session, identifier) || argc < 5) return 2;
	NSString *slot = [NSString stringWithUTF8String:argv[4]];
	if (![@[@"cold", @"held", @"race"] containsObject:slot]) return 2;
	NSURL *directoryURL = [session URLByAppendingPathComponent:slot isDirectory:YES];
	int directory = RootLockDirectory(directoryURL);
	if (directory < 0) return 2;
	close(directory);
	NSURL *url = [directoryURL URLByAppendingPathComponent:@".nv-root.lock"];
	if ([mode isEqualToString:@"root-lock-watch"])
		return RootLockWatch(directoryURL, [slot isEqualToString:@"race"],
			argc >= 6 ? [[NSString stringWithUTF8String:argv[5]] doubleValue] : 0, duration);
	if ([mode isEqualToString:@"root-lock-inspect"]) { RootLockInspect(directoryURL); return 0; }
	struct stat target;
	if (lstat([url fileSystemRepresentation], &target) != 0 || !S_ISREG(target.st_mode)) {
		Report(@"INCONCLUSIVE", @"AV-LOCK-target", @"refuse mutation of absent or nonregular lock");
		return 2;
	}
	NSError *error = nil;
	if ([mode isEqualToString:@"root-lock-replace"]) {
		Report(@"BEGIN", @"AV-LOCK-replace", @"explicit synthetic empty-file Foundation replacement");
		BOOL replaced = CoordinatedSafeReplace(url, [NSData data], &error) != nil;
		Report(replaced ? @"OBSERVE" : @"INCONCLUSIVE", @"AV-LOCK-replace",
			[NSString stringWithFormat:@"local-install=%d error=%@; does not prove peer delivery", replaced, ErrorCode(error)]);
		return replaced ? 0 : 2;
	}
	NSFileManager *manager = [NSFileManager defaultManager];
	if ([mode isEqualToString:@"root-lock-evict"]) {
		if (![manager isUbiquitousItemAtURL:url] || !WaitUntilUploaded(url, MIN(duration, 30))) {
			Report(@"INCONCLUSIVE", @"AV-LOCK-evict", @"positive ubiquitous/uploaded prerequisite unavailable");
			return 2;
		}
		Report(@"BEGIN", @"AV-LOCK-evict", @"request only; acceptance is not observed eviction");
		BOOL requested = [manager evictUbiquitousItemAtURL:url error:&error];
		BOOL observed = requested && WaitUntilNotDownloaded(url, MIN(duration, 30));
		Report(observed ? @"OBSERVE" : @"INCONCLUSIVE", @"AV-LOCK-evict", [NSString stringWithFormat:
			@"requested=%d not-downloaded-observed=%d error=%@", requested, observed, ErrorCode(error)]);
		return observed ? 0 : 2;
	}
	if ([mode isEqualToString:@"root-lock-download"]) {
		Report(@"BEGIN", @"AV-LOCK-download", @"request and coordinated exact empty read");
		BOOL requested = [manager startDownloadingUbiquitousItemAtURL:url error:&error];
		NSData *data = requested ? CoordinatedRead(url, &error) : nil;
		BOOL exact = data && [data length] == 0;
		Report(exact ? @"OBSERVE" : @"INCONCLUSIVE", @"AV-LOCK-download", [NSString stringWithFormat:
			@"requested=%d exact-empty=%d error=%@", requested, exact, ErrorCode(error)]);
		return exact ? 0 : 2;
	}
	return 2;
}
