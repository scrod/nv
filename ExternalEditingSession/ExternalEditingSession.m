//
//  ExternalEditingSession.m
//  Notation
//
//  Created by Zachary Schneirov on 8/12/26.

/*Copyright (c) 2026, Zachary Schneirov. All rights reserved.
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

/*
 * External-editing theory of operation:
 *
 * Notes stored as individual files are opened at their real path; the normal
 * notes-directory watcher notices changes to those files. Notes that cannot be
 * safely opened that way (especially encrypted single-database notes) use a
 * private 0600 scratch file as a temporary handoff to the editor instead.
 * One FSEvents stream watches all scratch files. FSEvents reports that something
 * changed, but not the contents, and its notification may be delayed. For each
 * session we therefore remember both the latest synchronized file bytes and the
 * latest text authored by the external editor. After either side changes, we
 * reread a complete file. If NV has no later edit, the external save is accepted
 * verbatim; only an NV edit newer than the file is three-way merged from the
 * external-editor base. Any resulting file replacement succeeds only if the file
 * still contains the bytes we just read, so an editor saving at the same moment
 * cannot be overwritten. A final read happens before the scratch file is deleted.
 */

#import "ExternalEditingSession.h"
#import "NotationPrefs.h"
#import "TemporaryFileCachePreparer.h"
#import "ExternalEditorListController.h"
#import "NoteObject.h"
#import "../NotationFileManager.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const NVExternalEditorClientKey = @"client";
static NSString * const NVExternalEditorContextKey = @"context";
static NSString * const NVExternalEditorPathKey = @"path";
static NSString * const NVExternalEditorDataKey = @"data";
static NSString * const NVExternalEditorMergeBaseDataKey = @"mergeBaseData";
static NSString * const NVExternalEditorProcessingKey = @"processing";
static NSString * const NVExternalEditorPendingEndKey = @"pendingEnd";
static NSString * const NVExternalEditorFinalReadAttemptsKey = @"finalReadAttempts";
static NSString * const NVExternalEditorPendingAcceptedDataKey = @"pendingAcceptedData";
static NSString * const NVExternalEditorWriteErrorReportedKey = @"writeErrorReported";
static NSString * const NVExternalEditorNoteModificationDateKey = @"noteModificationDate";
static NSString * const NVExternalEditorApplicationsKey = @"applications";
static NSString * const NVExternalEditorPendingOpenCountKey = @"pendingOpenCount";
static NSString * const NVFinishRequestPathsKey = @"paths";
static NSString * const NVFinishRequestCompletionKey = @"completion";
static NSString * const NVFinishRequestDeadlineKey = @"deadline";

static BOOL NVRemoveScratchFile(NSString *path) {
	if (unlink([path fileSystemRepresentation]) == 0 || errno == ENOENT) return YES;
	if (errno == EPERM) {
		struct stat info = { 0 };
		if (lstat([path fileSystemRepresentation], &info) == 0 &&
			chflags([path fileSystemRepresentation], info.st_flags & ~(UF_IMMUTABLE | UF_APPEND)) == 0 &&
			(unlink([path fileSystemRepresentation]) == 0 || errno == ENOENT))
			return YES;
	}
	return NO;
}

static NSData *NVReadStableScratchFile(NSString *path, struct timespec *changeTime) {
	// Read through an open descriptor and verify that it and the pathname still
	// refer to the same unchanged regular file. Many editors save safely by
	// writing a new file and renaming it over the old one; if that happens while
	// we read, return no result so the caller can try again later.
	int fd = open([path fileSystemRepresentation], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0) return nil;
	struct stat before = { 0 }, after = { 0 }, named = { 0 };
	NSData *result = nil;
	if (fstat(fd, &before) == 0 && S_ISREG(before.st_mode) && before.st_size >= 0 &&
		(uint64_t)before.st_size <= NSUIntegerMax) {
		NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
		uint8_t *bytes = [data mutableBytes];
		size_t remaining = (size_t)before.st_size;
		off_t offset = 0;
		BOOL readAll = YES;
		while (remaining) {
			ssize_t amount = pread(fd, bytes + offset, remaining, offset);
			if (amount < 0 && errno == EINTR) continue;
			if (amount <= 0) { readAll = NO; break; }
			offset += amount;
			remaining -= (size_t)amount;
		}
		if (readAll && fstat(fd, &after) == 0 &&
			lstat([path fileSystemRepresentation], &named) == 0 &&
			before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
			before.st_size == after.st_size && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
			before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec &&
			after.st_dev == named.st_dev && after.st_ino == named.st_ino &&
			after.st_size == named.st_size &&
			after.st_ctimespec.tv_sec == named.st_ctimespec.tv_sec &&
			after.st_ctimespec.tv_nsec == named.st_ctimespec.tv_nsec)
			result = data;
		if (result && changeTime) *changeTime = after.st_ctimespec;
	}
	close(fd);
	return result;
}

@interface ExternalEditingSession ()
- (BOOL)openURL:(NSURL*)URL inEditor:(ExternalEditor*)editor sessionPath:(NSString*)sessionPath;
- (BOOL)openPath:(NSString*)path inEditor:(ExternalEditor*)editor sessionPath:(NSString*)sessionPath;
- (NSString*)createScratchFileNamed:(NSString*)filename data:(NSData*)data;
- (NSDictionary*)sessionForClient:(id)client;
- (void)openDidCompleteForSessionPath:(NSString*)path application:(NSRunningApplication*)application;
- (void)runningApplicationTerminated:(NSNotification*)notification;
- (void)removeSessionAtPath:(NSString*)path;
- (void)checkFinishRequests;
- (void)invokeFinishCompletion:(NSArray*)arguments;
- (void)startScratchWatcher;
- (void)stopScratchWatcher;
- (BOOL)processScratchFileAtPath:(NSString*)path endingSession:(BOOL)endingSession;
- (void)scheduleScratchFilesChanged;
- (void)scratchFilesChanged;
@end

static void NVScratchEventCallback(ConstFSEventStreamRef stream, void *context,
	size_t count, void *paths, const FSEventStreamEventFlags flags[],
	const FSEventStreamEventId identifiers[]) {
	(void)stream; (void)count; (void)paths; (void)flags; (void)identifiers;
	[(ExternalEditingSession*)context performSelector:@selector(scheduleScratchFilesChanged)
		withObject:nil afterDelay:0.0];
}

@implementation ExternalEditingSession

static ExternalEditingSession *sharedExternalEditingSession;

+ (id)sharedExternalEditingSession {
	if (!sharedExternalEditingSession) sharedExternalEditingSession = [[ExternalEditingSession alloc] init];
	return sharedExternalEditingSession;
}

- (id)init {
	self = [super init];
	if (self) {
		if (sharedExternalEditingSession) {
			[self release];
			[NSException raise:NSInternalInconsistencyException
				format:@"ExternalEditingSession is a singleton - use [ExternalEditingSession sharedExternalEditingSession]"];
			return nil;
		}
		_filePathsBeingEdited = [[NSMutableDictionary alloc] init];
		_finishRequests = [[NSMutableArray alloc] init];
		[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
			selector:@selector(runningApplicationTerminated:)
			name:NSWorkspaceDidTerminateApplicationNotification object:nil];
	}
	return self;
}

- (void)dealloc {
	[self stopScratchWatcher];
	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
	for (NSString *path in [_filePathsBeingEdited allKeys])
		if (!NVRemoveScratchFile(path))
			NSLog(@"Unable to remove external-editing scratch file '%@': %s", path, strerror(errno));
	[_filePathsBeingEdited release];
	[_finishRequests release];
	[editingSpacePreparer setDelegate:nil];
	[editingSpacePreparer release];
	[super dealloc];
}

- (void)initializeDatabase:(NotationPrefs*)prefs {
	if ([_filePathsBeingEdited count]) {
		[self finishAllScratchEditingSessionsWithCompletionHandler:^(BOOL success) {
			if (success) [self initializeDatabase:prefs];
			else NSLog(@"Database external-editing storage change was canceled because a session could not be finished");
		}];
		return;
	}
	[self stopScratchWatcher];
	[editingSpacePreparer setDelegate:nil];
	[editingSpacePreparer release];
	editingSpacePreparer = [[TemporaryFileCachePreparer alloc] init];
	[editingSpacePreparer setDelegate:self];
	[editingSpacePreparer prepEditingSpaceIfNecessaryForNotationPrefs:prefs];
}

- (void)temporaryFileCachePreparerDidNotFinish:(TemporaryFileCachePreparer*)preparer {
	(void)preparer;
	NSLog(@"Could not prepare private external-editing storage");
}

- (void)temporaryFileCachePreparerFinished:(TemporaryFileCachePreparer*)preparer {
	(void)preparer;
}

- (void)startScratchWatcher {
	// Start this watcher only when a scratch file exists. Direct edits already use
	// the notes-directory watcher, and stopping here releases the scratch root as
	// soon as the last temporary editing session ends.
	[self stopScratchWatcher];
	NSString *root = [editingSpacePreparer preparedCachePath];
	if (![root length]) return;
	FSEventStreamContext context = { 0, self, CFRetain, CFRelease, CFCopyDescription };
	scratchEventStream = FSEventStreamCreate(NULL, NVScratchEventCallback, &context,
		(CFArrayRef)@[ root ], kFSEventStreamEventIdSinceNow, 0.2,
		kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents);
	if (!scratchEventStream) return;
	FSEventStreamSetDispatchQueue(scratchEventStream, dispatch_get_main_queue());
	if (!FSEventStreamStart(scratchEventStream)) [self stopScratchWatcher];
}

- (void)stopScratchWatcher {
	if (!scratchEventStream) return;
	FSEventStreamStop(scratchEventStream);
	FSEventStreamInvalidate(scratchEventStream);
	FSEventStreamRelease(scratchEventStream);
	scratchEventStream = NULL;
}

- (NSDictionary*)sessionForClient:(id)client {
	for (NSDictionary *session in [_filePathsBeingEdited allValues])
		if ([session objectForKey:NVExternalEditorClientKey] == client)
			return session;
	return nil;
}

- (NSUInteger)activeScratchEditingSessionCount {
	return [_filePathsBeingEdited count];
}

- (BOOL)hasActiveScratchEditingSessionForClient:(id)client {
	return [self sessionForClient:client] != nil;
}

- (void)beginScratchEditingSuspension {
	_scratchEditingSuspensionCount++;
}

- (void)endScratchEditingSuspension {
	NSAssert(_scratchEditingSuspensionCount, @"Unbalanced scratch-editing suspension");
	_scratchEditingSuspensionCount--;
}

- (void)invokeFinishCompletion:(NSArray*)arguments {
	void (^completion)(BOOL) = [arguments objectAtIndex:0];
	completion([[arguments objectAtIndex:1] boolValue]);
}

- (void)checkFinishRequests {
	if (![_finishRequests count]) return;
	NSSet *activePaths = [NSSet setWithArray:[_filePathsBeingEdited allKeys]];
	NSDate *now = [NSDate date];
	for (NSDictionary *request in [[_finishRequests copy] autorelease]) {
		NSSet *paths = [request objectForKey:NVFinishRequestPathsKey];
		BOOL finished = ![paths intersectsSet:activePaths];
		BOOL timedOut = !finished &&
			[[request objectForKey:NVFinishRequestDeadlineKey] compare:now] != NSOrderedDescending;
		if (!finished && !timedOut) continue;
		void (^completion)(BOOL) = [[request objectForKey:NVFinishRequestCompletionKey] copy];
		[_finishRequests removeObjectIdenticalTo:request];
		if (timedOut) {
			for (NSString *path in paths) {
				NSMutableDictionary *session = [_filePathsBeingEdited objectForKey:path];
				BOOL anotherRequestNeedsPath = NO;
				for (NSDictionary *other in _finishRequests)
					if ([[other objectForKey:NVFinishRequestPathsKey] containsObject:path]) {
						anotherRequestNeedsPath = YES;
						break;
					}
				if (!anotherRequestNeedsPath && session) {
					[session removeObjectForKey:NVExternalEditorPendingEndKey];
					[session removeObjectForKey:NVExternalEditorFinalReadAttemptsKey];
					[NSObject cancelPreviousPerformRequestsWithTarget:self
						selector:@selector(abortEditingFile:) object:path];
				}
			}
		}
		NSArray *arguments = @[ completion, @(finished) ];
		/* Deferred application termination runs a modal loop. Common modes let this
		 * completion deliver AppKit's final quit/cancel answer from that loop. */
		[self performSelector:@selector(invokeFinishCompletion:)
			withObject:arguments afterDelay:0.0
			inModes:@[ NSRunLoopCommonModes ]];
		[completion release];
	}
}

- (void)finishScratchEditingSessionsForClients:(NSArray*)clients
	completionHandler:(void (^)(BOOL success))completionHandler {
	NSMutableSet *paths = [NSMutableSet set];
	for (NSString *path in [_filePathsBeingEdited allKeys]) {
		NSDictionary *session = [_filePathsBeingEdited objectForKey:path];
		for (id client in clients)
			if ([session objectForKey:NVExternalEditorClientKey] == client) {
				[paths addObject:path];
				break;
			}
	}
	void (^completion)(BOOL) = completionHandler ? [completionHandler copy] :
		[^(BOOL success) { (void)success; } copy];
		NSDictionary *request = @{ NVFinishRequestPathsKey: paths, NVFinishRequestCompletionKey: completion,
			NVFinishRequestDeadlineKey: [NSDate dateWithTimeIntervalSinceNow:5.0] };
	[completion release];
	[_finishRequests addObject:request];
	for (NSString *path in paths) {
		[[_filePathsBeingEdited objectForKey:path] setObject:@YES
			forKey:NVExternalEditorPendingEndKey];
		[self abortEditingFile:path];
	}
	[self checkFinishRequests];
}

- (void)finishAllScratchEditingSessionsWithCompletionHandler:
	(void (^)(BOOL success))completionHandler {
	NSMutableArray *clients = [NSMutableArray array];
	for (NSDictionary *session in [_filePathsBeingEdited allValues]) {
		id client = [session objectForKey:NVExternalEditorClientKey];
		if (client && [clients indexOfObjectIdenticalTo:client] == NSNotFound)
			[clients addObject:client];
	}
	[self finishScratchEditingSessionsForClients:clients completionHandler:completionHandler];
}

- (void)removeSessionAtPath:(NSString*)path {
	if (![_filePathsBeingEdited objectForKey:path]) return;
	[_filePathsBeingEdited removeObjectForKey:path];
	[self checkFinishRequests];
}

- (void)openDidCompleteForSessionPath:(NSString*)path
	application:(NSRunningApplication*)application {
	NSMutableDictionary *session = [_filePathsBeingEdited objectForKey:path];
	if (!session) return;
	NSUInteger pending = [[session objectForKey:NVExternalEditorPendingOpenCountKey]
		unsignedIntegerValue];
	if (pending > 1)
		[session setObject:@(pending - 1) forKey:NVExternalEditorPendingOpenCountKey];
	else [session removeObjectForKey:NVExternalEditorPendingOpenCountKey];
	NSMutableSet *applications = [session objectForKey:NVExternalEditorApplicationsKey];
	if (application) {
		if (!applications) {
			applications = [NSMutableSet set];
			[session setObject:applications forKey:NVExternalEditorApplicationsKey];
		}
		[applications addObject:application];
		/* The termination notification may have arrived before this completion. */
		if ([application isTerminated]) [applications removeObject:application];
	}
	if (![applications count] &&
		![[session objectForKey:NVExternalEditorPendingOpenCountKey] unsignedIntegerValue])
		[self abortEditingFile:path];
}

- (void)runningApplicationTerminated:(NSNotification*)notification {
	if (![NSThread isMainThread]) {
		[self performSelectorOnMainThread:_cmd withObject:notification waitUntilDone:NO];
		return;
	}
	NSRunningApplication *application = [[notification userInfo]
		objectForKey:NSWorkspaceApplicationKey];
	if (!application) return;
	for (NSString *path in [[[_filePathsBeingEdited allKeys] copy] autorelease]) {
		NSMutableDictionary *session = [_filePathsBeingEdited objectForKey:path];
		NSMutableSet *applications = [session objectForKey:NVExternalEditorApplicationsKey];
		if (![applications containsObject:application]) continue;
		[applications removeObject:application];
		if (![applications count] &&
			![[session objectForKey:NVExternalEditorPendingOpenCountKey] unsignedIntegerValue])
			[self abortEditingFile:path];
	}
}

- (void)noteContentsDidChange:(NoteObject*)note {
	NSDate *changeDate = [NSDate date];
	void (^recordChange)(void) = ^{
		NSMutableDictionary *session = (NSMutableDictionary*)[self sessionForClient:note];
		if (!session || [[session objectForKey:NVExternalEditorProcessingKey] boolValue]) return;
		[session setObject:changeDate forKey:NVExternalEditorNoteModificationDateKey];
		[self scheduleScratchFilesChanged];
	};
	if ([NSThread isMainThread]) recordChange();
	else dispatch_async(dispatch_get_main_queue(), recordChange);
}

- (void)scheduleScratchFilesChanged {
	// A body change can arrive once per keystroke. Collapse those notifications
	// into one pass after the current UI, undo, import, or sync callback returns.
	[NSObject cancelPreviousPerformRequestsWithTarget:self
		selector:@selector(scratchFilesChanged) object:nil];
	[self performSelector:@selector(scratchFilesChanged) withObject:nil afterDelay:0.0];
}

- (BOOL)openURL:(NSURL*)URL inEditor:(ExternalEditor*)editor
	sessionPath:(NSString*)sessionPath {
	if (!editor) editor = [[ExternalEditorListController sharedInstance] defaultExternalEditor];
	NSURL *applicationURL = [editor resolvedURL];
	if (!URL || !applicationURL) return NO;
	if (sessionPath) {
		NSMutableDictionary *session = [_filePathsBeingEdited objectForKey:sessionPath];
		NSUInteger pending = [[session objectForKey:NVExternalEditorPendingOpenCountKey]
			unsignedIntegerValue] + 1;
		[session setObject:@(pending) forKey:NVExternalEditorPendingOpenCountKey];
	}
	NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
	[configuration setAddsToRecentItems:NO];
	[[NSWorkspace sharedWorkspace] openURLs:@[ URL ]
		withApplicationAtURL:applicationURL configuration:configuration
		completionHandler:^(NSRunningApplication *application, NSError *error) {
			if (!application && error) NSLog(@"Could not open external editor: %@", error);
			if (sessionPath) dispatch_async(dispatch_get_main_queue(), ^{
				[self openDidCompleteForSessionPath:sessionPath application:application];
			});
		}];
	return YES;
}

- (BOOL)openPath:(NSString*)path inEditor:(ExternalEditor*)editor
	sessionPath:(NSString*)sessionPath {
	return [path length] ? [self openURL:[NSURL fileURLWithPath:path]
		inEditor:editor sessionPath:sessionPath] : NO;
}

- (NSString*)createScratchFileNamed:(NSString*)filename data:(NSData*)data {
	// Create the handoff file exclusively, with permissions that allow only the
	// current user to read it. For an encrypted database the prepared root is a
	// RAM-backed volume, so the note's plain text is not left on persistent disk;
	// an explicit export is the separate path that intentionally writes a copy.
	NSString *root = [editingSpacePreparer preparedCachePath];
	if (![root length] || !data) return nil;
	if (!scratchEventStream) [self startScratchWatcher];
	if (!scratchEventStream) return nil;
	NSString *base = [[filename lastPathComponent] stringByDeletingPathExtension];
	if (![base length]) base = @"Untitled Text";
	for (NSUInteger sequence = 0; sequence < 10000; sequence++) {
		NSString *name = sequence ? [NSString stringWithFormat:@"%@ %03lu.txt", base,
			(unsigned long)sequence] : [base stringByAppendingPathExtension:@"txt"];
		NSString *path = [root stringByAppendingPathComponent:name];
		int fd = open([path fileSystemRepresentation],
			O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
		if (fd < 0) {
			if (errno == EEXIST) continue;
			return nil;
		}
		const uint8_t *bytes = [data bytes];
		size_t remaining = [data length];
		BOOL wrote = YES;
		while (remaining) {
			ssize_t amount = write(fd, bytes, remaining);
			if (amount < 0 && errno == EINTR) continue;
			if (amount <= 0) { wrote = NO; break; }
			bytes += amount;
			remaining -= (size_t)amount;
		}
		if (wrote) wrote = fsync(fd) == 0;
		close(fd);
		if (wrote) return path;
		(void)unlink([path fileSystemRepresentation]);
		return nil;
	}
	return nil;
}

- (BOOL)editNote:(NoteObject*)note inEditor:(ExternalEditor*)editor
	context:(NSDictionary*)context {
	// Prefer the real note path whenever the chosen editor understands the file's
	// format. Otherwise make a scratch handoff. The session remembers the bytes
	// given to the editor as its "starting version"; later changes can then be
	// compared with that version and applied without writing database plaintext
	// to persistent storage.
	if (!note) goto failed;
	if (!editor) editor = [[ExternalEditorListController sharedInstance] defaultExternalEditor];
	if ([editor canEditNoteDirectly:note]) {
		NSURL *URL = [note noteFileURL];
		if ([self openURL:URL inEditor:editor sessionPath:nil]) return YES;
		goto failed;
	}
	/* A settings sheet can commit a storage or encryption transition when its
	 * button is pressed. Do not let a new plaintext scratch session appear
	 * between the initial lifecycle check and that commit. Direct-file editing
	 * above is unaffected. */
	if (_scratchEditingSuspensionCount) goto failed;
	for (NSWindow *window in [NSApp windows]) if ([window attachedSheet]) goto failed;
	NSDictionary *existing = [self sessionForClient:note];
	if (existing)
		return [self openPath:[existing objectForKey:NVExternalEditorPathKey]
			inEditor:editor sessionPath:[existing objectForKey:NVExternalEditorPathKey]];
	NSData *data = [[[note contentString] string] dataUsingEncoding:NSUTF8StringEncoding];
	NSString *path = [self createScratchFileNamed:filenameOfNote(note) data:data];
	if (!path) goto failed;
	NSMutableDictionary *session = [NSMutableDictionary dictionaryWithObjectsAndKeys:
		note, NVExternalEditorClientKey,
		path, NVExternalEditorPathKey, data, NVExternalEditorDataKey,
		data, NVExternalEditorMergeBaseDataKey,
		nil];
	if (context) [session setObject:context forKey:NVExternalEditorContextKey];
	[_filePathsBeingEdited setObject:session forKey:path];
	if ([self openPath:path inEditor:editor sessionPath:path]) return YES;
	[self abortEditingFile:path];
failed:
	NSBeep();
	return NO;
}

- (BOOL)processScratchFileAtPath:(NSString*)path endingSession:(BOOL)endingSession {
	/*
	 * This is the one place that both processes scratch changes and ends a
	 * session. Retain the session while calling NoteObject: resolving a conflict
	 * can immediately change the selected note and remove the session from the
	 * dictionary. The session's `data` is the latest synchronized file snapshot;
	 * `mergeBaseData` is the last version accepted from the external editor. First
	 * merge any different file bytes into the note and make that result durable in
	 * the database journal, then install the current note only if the file still
	 * has the bytes just read. If the caller is ending the session, perform only
	 * the final read, merge, and journal synchronization before deleting the file.
	 */
	NSMutableDictionary *session = [[_filePathsBeingEdited objectForKey:path] retain];
	if (!session) return YES;
	if ([[session objectForKey:NVExternalEditorProcessingKey] boolValue]) {
		if (endingSession) [session setObject:@YES forKey:NVExternalEditorPendingEndKey];
		[session release];
		return YES;
	}

	struct timespec changeTime = { 0 };
	NSData *data = NVReadStableScratchFile(path, &changeTime);
	if (!data) {
		BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
		if (endingSession) {
			NSUInteger attempts = [[session objectForKey:NVExternalEditorFinalReadAttemptsKey]
				unsignedIntegerValue] + 1;
			if (!exists && attempts >= 20) {
				if ([_filePathsBeingEdited objectForKey:path] == session)
					[self removeSessionAtPath:path];
			} else {
				[session setObject:@YES forKey:NVExternalEditorPendingEndKey];
			[session setObject:@(attempts) forKey:NVExternalEditorFinalReadAttemptsKey];
			}
		}
		[session release];
		return NO;
	}
	[session removeObjectForKey:NVExternalEditorFinalReadAttemptsKey];

	NSData *baseData = [session objectForKey:NVExternalEditorDataKey];
	if (![data isEqualToData:baseData]) {
		NSData *pendingAcceptedData = [session objectForKey:NVExternalEditorPendingAcceptedDataKey];
		if (pendingAcceptedData) {
			NoteObject *client = [session objectForKey:NVExternalEditorClientKey];
			if (![[client delegate] makeNoteDurableForExternalEditing:client]) {
				[session release];
				return NO;
			}
			[session setObject:pendingAcceptedData forKey:NVExternalEditorDataKey];
			[session setObject:pendingAcceptedData forKey:NVExternalEditorMergeBaseDataKey];
			[session removeObjectForKey:NVExternalEditorPendingAcceptedDataKey];
			baseData = pendingAcceptedData;
			if ([data isEqualToData:baseData]) goto externalDataAccepted;
		}
		[session setObject:@YES forKey:NVExternalEditorProcessingKey];
		NoteObject *client = [session objectForKey:NVExternalEditorClientKey];
		NSData *noteData = [[[client contentString] string] dataUsingEncoding:NSUTF8StringEncoding];
		NSDate *fileChangeDate = [NSDate dateWithTimeIntervalSince1970:
			changeTime.tv_sec + changeTime.tv_nsec / 1.0e9];
		NSDate *noteModificationDate = [session objectForKey:
			NVExternalEditorNoteModificationDateKey];
		NSData *mergeBaseData = [session objectForKey:NVExternalEditorMergeBaseDataKey];
		BOOL noteHasUnsynchronizedChanges = ![noteData isEqualToData:baseData];
		BOOL externalSaveIsNewer = noteModificationDate &&
			[fileChangeDate compare:noteModificationDate] == NSOrderedDescending;
		if (!noteHasUnsynchronizedChanges || externalSaveIsNewer) mergeBaseData = noteData;
		if (!mergeBaseData) mergeBaseData = baseData;
		BOOL accepted = [client externalEditingSession:self didModifyFileData:data baseData:mergeBaseData path:path
			context:[session objectForKey:NVExternalEditorContextKey]];
		[session removeObjectForKey:NVExternalEditorProcessingKey];
		if ([_filePathsBeingEdited objectForKey:path] != session) {
			[session release];
			return YES;
		}
		if (!accepted) {
			[session release];
			return NO;
		}
		if (![[client delegate] makeNoteDurableForExternalEditing:client]) {
			[session setObject:data forKey:NVExternalEditorPendingAcceptedDataKey];
			[session release];
			return NO;
		}
	externalDataAccepted:
		[session setObject:data forKey:NVExternalEditorDataKey];
		NSString *externalText = [[[NSString alloc] initWithData:data
			encoding:NSUTF8StringEncoding] autorelease];
		if (externalText)
			[session setObject:data forKey:NVExternalEditorMergeBaseDataKey];
	}
	if (endingSession || [[session objectForKey:NVExternalEditorPendingEndKey] boolValue]) {
		if ([_filePathsBeingEdited objectForKey:path] == session) {
			if (NVRemoveScratchFile(path))
				[self removeSessionAtPath:path];
			else {
				NSLog(@"Unable to remove external-editing scratch file '%@': %s", path,
					strerror(errno));
				[session release];
				return NO;
			}
		}
	} else {
		NoteObject *client = [session objectForKey:NVExternalEditorClientKey];
		NSData *noteData = [[[client contentString] string]
			dataUsingEncoding:NSUTF8StringEncoding];
		if ([noteData isEqualToData:data]) {
			[session removeObjectForKey:NVExternalEditorNoteModificationDateKey];
			[session removeObjectForKey:NVExternalEditorWriteErrorReportedKey];
		} else {
			NSError *writeError = nil;
			NSString *directory = [path stringByDeletingLastPathComponent];
			int directoryFD = open([directory fileSystemRepresentation],
				O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
			BOOL wrote = directoryFD >= 0 &&
				NVReplaceDataAtomicallyAtDirectoryFileDescriptor(directoryFD, noteData,
					[path lastPathComponent], data, &writeError);
			if (directoryFD >= 0) close(directoryFD);
			else writeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
				userInfo:@{ NSFilePathErrorKey: directory }];
			if (wrote) {
				if (![session objectForKey:NVExternalEditorMergeBaseDataKey])
					[session setObject:data forKey:NVExternalEditorMergeBaseDataKey];
				[session setObject:noteData forKey:NVExternalEditorDataKey];
				[session removeObjectForKey:NVExternalEditorNoteModificationDateKey];
				[session removeObjectForKey:NVExternalEditorWriteErrorReportedKey];
			} else if ([[writeError domain] isEqualToString:NSPOSIXErrorDomain] &&
				[writeError code] == EAGAIN) {
				[session release];
				return NO;
			} else if (![session objectForKey:NVExternalEditorWriteErrorReportedKey]) {
				NSLog(@"Could not update external-editing scratch file '%@': %@", path,
					writeError);
				NSBeep();
				[session setObject:@YES forKey:NVExternalEditorWriteErrorReportedKey];
			}
		}
	}
	[session release];
	return YES;
}

- (void)scratchFilesChanged {
	// FSEvents supplies delayed, combined "something changed" hints rather than
	// file contents. Check every active session and retry reads or conditional
	// writes that lost a race with the external editor.
	BOOL needsRetry = NO;
	for (NSString *path in [[[_filePathsBeingEdited allKeys] copy] autorelease])
		if (![self processScratchFileAtPath:path endingSession:NO]) needsRetry = YES;
	if (needsRetry)
		[self performSelector:@selector(scratchFilesChanged) withObject:nil afterDelay:0.1];
	else if (![_filePathsBeingEdited count])
		[self stopScratchWatcher];
}

- (void)abortEditingFile:(NSString*)path {
	// Process one last complete version before removing the private handoff file.
	if (!path) return;
	if ([_filePathsBeingEdited objectForKey:path])
		[self processScratchFileAtPath:path endingSession:YES];
	if ([_filePathsBeingEdited objectForKey:path])
		/* Final-read retries must continue while the quit confirmation is modal. */
		[self performSelector:@selector(abortEditingFile:) withObject:path afterDelay:0.1
			inModes:@[ NSRunLoopCommonModes ]];
	[self checkFinishRequests];
	if (![_filePathsBeingEdited count]) [self stopScratchWatcher];
}

- (void)abortAllEditingSessionsForClient:(id)client {
	for (NSString *path in [[[_filePathsBeingEdited allKeys] copy] autorelease]) {
		NSDictionary *session = [_filePathsBeingEdited objectForKey:path];
		if ([session objectForKey:NVExternalEditorClientKey] == client)
			[self abortEditingFile:path];
	}
}

@end
