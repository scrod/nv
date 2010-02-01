//
//  SimplenoteSession.m
//  Notation
//
//  Created by Zachary Schneirov on 12/4/09.
//  Copyright 2009 Zachary Schneirov. All rights reserved.
//

#import "SimplenoteSession.h"
#import "SyncResponseFetcher.h"
#import "SimplenoteEntryCollector.h"
#import "NSCollection_utils.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "NSArray+BSJSONAdditions.h"
#import "AttributedPlainText.h"
#import "InvocationRecorder.h"
#import "SynchronizedNoteProtocol.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"

//this class constitutes the simple-note-specific glue between HTTP fetching 
//and NotationSyncServiceManager, which is NotationController
//much of this is probably useful enough for other services to be abstracted into a superclass

NSString *SimplenoteServiceName = @"SN";
NSString *SimplenoteSeparatorKey = @"SepStr";

@implementation SimplenoteSession

+ (NSString*)localizedServiceTitle {
	return NSLocalizedString(@"Simplenote", @"human-readable name for the Simplenote service");
}

+ (NSString*)serviceName {
	return SimplenoteServiceName;
}

+ (NSString*)nameOfKeyElement {
	return @"key";
}

+ (NSURL*)servletURLWithPath:(NSString*)path parameters:(NSDictionary*)params {
	NSAssert(path != nil, @"path is required");
	//path example: "/api/note"
	
	NSString *queryStr = params ? [NSString stringWithFormat:@"?%@", [params URLEncodedString]] : @"";
	return [NSURL URLWithString:[NSString stringWithFormat:@"https://simple-note.appspot.com%@%@", path, queryStr]];
}

+ (SCNetworkReachabilityRef)createReachabilityRefWithCallback:(SCNetworkReachabilityCallBack)callout target:(id)aTarget {
	SCNetworkReachabilityRef reachableRef = NULL;
	
	if ((reachableRef = SCNetworkReachabilityCreateWithName(NULL, [[[SimplenoteSession servletURLWithPath:
																   @"/" parameters:nil] host] UTF8String]))) {
		SCNetworkReachabilityContext context = {0, aTarget, NULL, NULL, NULL};
		if (SCNetworkReachabilitySetCallback(reachableRef, callout, &context)) {
			if (!SCNetworkReachabilityScheduleWithRunLoop(reachableRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)) {
				NSLog(@"SCNetworkReachabilityScheduleWithRunLoop error: %d", SCError());
				CFRelease(reachableRef);
				return NULL;
			}
		}
	}
	return reachableRef;
}

- (NSComparisonResult)localEntry:(NSDictionary*)localEntry compareToRemoteEntry:(NSDictionary*)remoteEntry {
	//simplenote-specific logic to determine whether to upload localEntry as a newer version of remoteEntry
	NSNumber *modifiedLocalNumber = [localEntry objectForKey:@"modify"];
	NSNumber *modifiedRemoteNumber = [remoteEntry objectForKey:@"modify"];
	
	if ([modifiedLocalNumber isKindOfClass:[NSNumber class]] && [modifiedRemoteNumber isKindOfClass:[NSNumber class]]) {
		CFAbsoluteTime localAbsTime = floor([modifiedLocalNumber doubleValue]);
		CFAbsoluteTime remoteAbsTime = floor([modifiedRemoteNumber doubleValue]);
		
		if (localAbsTime > remoteAbsTime) {
			return NSOrderedDescending;
		} else if (localAbsTime < remoteAbsTime) {
			return NSOrderedAscending;
		}
		return NSOrderedSame;
	}
	//no comparison posible is the same as no comparison necessary for this method; 
	//the locally-added or remotely-added cases should not need to look at modification dates
	NSLog(@"%@ or %@ are lacking a date-modified property!", localEntry, remoteEntry);
	return NSOrderedSame;
}

- (BOOL)remoteEntryWasMarkedDeleted:(NSDictionary*)remoteEntry {
	return [[remoteEntry objectForKey:@"deleted"] intValue] == 1;
}
- (BOOL)entryHasLocalChanges:(NSDictionary*)entry {
	return [[entry objectForKey:@"dirty"] intValue] == 1;
}

+ (void)registerLocalModificationForNote:(id <SynchronizedNote>)aNote {
	//if this note has been synced with this service at least once, mirror the mod date
	NSDictionary *aDict = [[aNote syncServicesMD] objectForKey:SimplenoteServiceName];
	if (aDict) {
		NSAssert([aNote isKindOfClass:[NoteObject class]], @"can't modify a non-note!");
		[aNote setSyncObjectAndKeyMD:[NSDictionary dictionaryWithObject:
									  [NSNumber numberWithDouble:modifiedDateOfNote((NoteObject*)aNote)] forKey:@"modify"]
						  forService:SimplenoteServiceName];
		
	} //if note has no metadata for this service, mod times don't matter because it will be added, anyway
}

- (id)initWithNotationPrefs:(NotationPrefs*)prefs {
	if (![prefs syncServiceIsEnabled:SimplenoteServiceName]) {
		NSLog(@"notationPrefs says this service is disabled--stop it!");
		return nil;
	}
	
	if ([self initWithUsername:[[prefs syncAccountForServiceName:SimplenoteServiceName] objectForKey:@"username"] 
				   andPassword:[prefs syncPasswordForServiceName:SimplenoteServiceName]]) {
		return self;
	}
	return nil;
}

- (id)initWithUsername:(NSString*)aUserString andPassword:(NSString*)aPassString {
	
	if ([super init]) {
		if (![(emailAddress = [aUserString retain]) length]) {
			NSLog(@"%s: empty email address", _cmd);
			return nil;
		}
		if (![(password = [aPassString retain]) length]) {
			NSLog(@"%s: empty password", _cmd);
			return nil;
		}
		notesToSuppressPushing = [[NSCountedSet alloc] init];
		notesBeingModified = [[NSMutableSet alloc] init];
		unsyncedServiceNotes = [[NSMutableSet alloc] init];
		collectorsInProgress = [[NSMutableSet alloc] init];
	}
	return self;
}

- (NSString*)description {
	return [NSString stringWithFormat:@"SimplenoteSession<%@,%X>", emailAddress, self];
}

- (id)copyWithZone:(NSZone *)zone {
	
	SimplenoteSession *newSession = [[SimplenoteSession alloc] initWithUsername:emailAddress andPassword:password];
	newSession->authToken = [authToken copyWithZone:zone];
	newSession->lastSyncedTime = [lastSyncedTime copyWithZone:zone];
	newSession->delegate = delegate;
	
	//may not want these to come with the copy, as they are specific to transactions-in-progress
//	newSession->notesToSuppressPushing = [notesToSuppressPushing mutableCopyWithZone:zone];
//	newSession->notesBeingModified = [notesBeingModified mutableCopyWithZone:zone];
//	newSession->queuedNoteInvocations = [queuedNoteInvocations mutableCopyWithZone:zone];
	
	return newSession;
}

- (SyncResponseFetcher*)loginFetcher {
	
	//init fetcher for login method; credentials POSTed in body
	if (!loginFetcher) {
		NSURL *loginURL = [SimplenoteSession servletURLWithPath:@"/api/login" parameters:nil];
		loginFetcher = [[SyncResponseFetcher alloc] initWithURL:loginURL bodyStringAsUTF8B64:
						[[NSDictionary dictionaryWithObjectsAndKeys: 
						  emailAddress, @"email", password, @"password", nil] URLEncodedString] delegate:self];
	}
	return loginFetcher;
}

- (SyncResponseFetcher*)listFetcher {
	if (!listFetcher) {
		NSAssert(authToken != nil, @"no authtoken found");
		NSURL *listURL = [SimplenoteSession servletURLWithPath:@"/api/index" parameters:
						  [NSDictionary dictionaryWithObjectsAndKeys: emailAddress, @"email", authToken, @"auth", nil]];
		listFetcher = [[SyncResponseFetcher alloc] initWithURL:listURL POSTData:nil delegate:self];
	}
	return listFetcher;
}

- (BOOL)_checkToken {
	return authToken != nil;
}

- (NSString*)statusText {
	//current status (logging-in, getting index, etc.) minus any info. about collectorsInProgress
	//one line only
		
	if ([listFetcher isRunning]) {
		
		return NSLocalizedString(@"Getting the list of notes...", nil);
		
	} else if ([loginFetcher isRunning]) {
		
		return NSLocalizedString(@"Logging in...", nil);
		
	} else if (lastErrorString) {
		
		return [NSLocalizedString(@"Error: ", @"string to prefix a sync service error") stringByAppendingString:lastErrorString];
		
	} else if (lastSyncedTime) {
		//I suppose -descriptionWithLocale: returns a localized description?
		return [NSLocalizedString(@"Last sync: ", @"label to prefix last sync time in the status menu") 
				stringByAppendingString:[lastSyncedTime descriptionWithLocale:nil]];
	} else if ([collectorsInProgress count]) {
		//probably won't display this very often
		return [NSString stringWithFormat:NSLocalizedString(@"%u update(s) in progress", nil), [collectorsInProgress count]];
	} else {
		return NSLocalizedString(@"Not synchronized yet", nil);
	}
}

- (void)_updateSyncTime {
	[lastSyncedTime release];
	lastSyncedTime = [[NSDate date] retain];
}


- (void)_stoppedWithErrorString:(NSString*)aString {
	[lastErrorString autorelease];
	lastErrorString = [aString copy];
	
	if (!aString) {
		[self _updateSyncTime];
	}
	[delegate syncSession:self didStopWithError:lastErrorString];
}

- (NSString*)lastError {
	return lastErrorString;
}

- (BOOL)isRunning {
	return [loginFetcher isRunning] || [listFetcher isRunning] || [collectorsInProgress count];
}

- (NSSet*)activeTasks {
	//returns an array of id<SyncServiceTask> objs
	return collectorsInProgress;
}

- (void)stop {
	[pushTimer invalidate];
	pushTimer = nil;
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleSyncServiceChanges:) object:nil];
	[unsyncedServiceNotes removeAllObjects]; //caution: will cause NV not to wait before quitting regardless of unsynced changes
	[queuedNoteInvocations removeAllObjects];
	[[[collectorsInProgress copy] autorelease] makeObjectsPerformSelector:@selector(stop)];
	[loginFetcher cancel];
	[listFetcher cancel];
}

//these two methods and probably more are general enough to be abstracted into NotationSyncServiceManager

- (void)schedulePushForNote:(id <SynchronizedNote>)aNote {
	
	//guard against the case that notes in this push were originally triggered by a full sync
	//(in which case these notes should have been suppressed)

	if (![notesToSuppressPushing containsObject:aNote]) {
		
		//to allow swapping w/ DeletedNoteObjects and vise versa
		[unsyncedServiceNotes removeObject:aNote];
		[unsyncedServiceNotes addObject:aNote];
		
		//push every 20 seconds after the first change, and 6 seconds after the last change
		if (!pushTimer) pushTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(handleSyncServiceChanges:) userInfo:nil repeats:NO];
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleSyncServiceChanges:) object:nil];
		[self performSelector:@selector(handleSyncServiceChanges:) withObject:nil afterDelay:7.0];
	}
}

- (BOOL)hasUnsyncedChanges {
	return [unsyncedServiceNotes count] > 0;
}

- (void)handleSyncServiceChanges:(NSTimer*)aTimer {
	[pushTimer invalidate];
	pushTimer = nil;
	[self pushSyncServiceChanges];
}	

- (BOOL)pushSyncServiceChanges {
	//return no if we didn't need to push the changes (e.g., they were already being handled or there weren't any to push)
	
	if ([unsyncedServiceNotes count] > 0) {
		
		if ([listFetcher isRunning]) {
			NSLog(@"%s: not pushing because a full sync index is in progress", _cmd);
			return NO;
		}
		
		//now actively ADD/UPDATE/DELETE these notes directly, depending on presence of syncServicesMD dicts
		//this is only part of a unidirectional sync; a full bi-directional sync could handle these events on its own
		
		NSMutableArray *notesToCreate = [NSMutableArray array];
		NSMutableArray *notesToUpdate = [NSMutableArray array];
		NSMutableArray *notesToDelete = [NSMutableArray array];
		
		NSArray *notes = [unsyncedServiceNotes allObjects];
		NSUInteger i = 0;
		for (i = 0; i<[notes count]; i++) {
			id <SynchronizedNote> aNote = [notes objectAtIndex:i];
			
			if ([[aNote syncServicesMD] objectForKey:SimplenoteServiceName]) {
				//this note has already been synced; if it is a deleted note, queue it to be deleted; 
				//otherwise queue it to be updated
				if ([aNote isKindOfClass:[DeletedNoteObject class]]) {
					[notesToDelete addObject:aNote];
				} else {
					//this is a push sync, so this note may or may not already be newer on the server
					//we should make sure to do a FULL sync before pushing (e.g., when the application launches)
					
					[notesToUpdate addObject:aNote];
				}
			} else {
				if ([aNote isKindOfClass:[NoteObject class]]) {
					//note has no service MD and thus has not been synced (if it has, this will create a duplicate)
					//queue the note to be created; it doesn't have any metadata for this service
					[notesToCreate addObject:aNote];
				} else {
					NSLog(@"not creating an already-deleted note %@", aNote);
				}
			}
		}
		
		[self startCreatingNotes:notesToCreate];
		[self startModifyingNotes:notesToUpdate];
		[self startDeletingNotes:notesToDelete];
		
		[unsyncedServiceNotes removeAllObjects];
		return YES;
    }
	return NO;
}

- (void)_clearAuthTokenAndDependencies {
	[listFetcher autorelease];
	listFetcher = nil;
	[authToken autorelease];
	authToken = nil;	
}


- (BOOL)startFetchingListForFullSync {
	//full bi-directional sync
	
	//pushing updates can race against grabbing the list of notes
	//if the list is requested first, and a push occurs before the list returns, then the list might not reflect that change
	//and the full-sync logic would do the wrong thing due to assuming that any note's syncServicesMD info would always be in the list
	//thus, all notes in unsyncedServiceNotes and notesBeingModified should be allowed to fully complete first
	
	BOOL didStart = NO;
	
	if (![self _checkToken]) {
		
		InvocationRecorder *invRecorder = [InvocationRecorder invocationRecorder];
		[[invRecorder prepareWithInvocationTarget:self] startFetchingListForFullSync];
		didStart = [[self loginFetcher] startWithSuccessInvocation:[invRecorder invocation]];
		
	} else if (![notesBeingModified count] && ![listFetcher isRunning] && ![collectorsInProgress count]) {
		
		//token already exists; just fetch the list directly
		didStart = [[self listFetcher] start];
		
	} else {
		if ([collectorsInProgress count]) {
			NSLog(@"not requesting list because collections (%@) are still in progress", collectorsInProgress);
		} else {
			NSLog(@"not requesting list because it is already being fetched or notes are still being modified");
		}
	}
	
	if (didStart && !lastSyncedTime) {
		//don't report that we started syncing _here_ unless it was the first time doing so; 
		//after the first time alert the user only when actual modifications are occurring
		[delegate syncSessionProgressStarted:self];
	}
	return didStart;
}

- (void)startCollectingAddedNotesWithEntries:(NSArray*)entries mergingWithNotes:(NSArray*)someNotes {
	if (![entries count]) {
		return;
	}
	if (!authToken) {
		InvocationRecorder *invRecorder = [InvocationRecorder invocationRecorder];
		[[invRecorder prepareWithInvocationTarget:self] startCollectingAddedNotesWithEntries:entries mergingWithNotes:someNotes];
		[[self loginFetcher] startWithSuccessInvocation:[invRecorder invocation]];
	} else {
		SimplenoteEntryCollector *collector = [[SimplenoteEntryCollector alloc] 
											   initWithEntriesToCollect:entries authToken:authToken email:emailAddress];
		[collector setRepresentedObject:someNotes];
		[self _registerCollector:collector];
		
		[collector startCollectingWithCallback:[someNotes count] ? 
		 @selector(addedEntriesToMergeCollectorDidFinish:) : @selector(addedEntryCollectorDidFinish:) collectionDelegate:self];
		[collector autorelease];
	}
}

- (void)startCollectingChangedNotesWithEntries:(NSArray*)entries {	
	if (![entries count]) {
		return;
	}
	if (!authToken) {
		InvocationRecorder *invRecorder = [InvocationRecorder invocationRecorder];
		[[invRecorder prepareWithInvocationTarget:self] startCollectingChangedNotesWithEntries:entries];
		[[self loginFetcher] startWithSuccessInvocation:[invRecorder invocation]];
	} else {
		SimplenoteEntryCollector *collector = [[SimplenoteEntryCollector alloc] 
											   initWithEntriesToCollect:entries authToken:authToken email:emailAddress];
		[self _registerCollector:collector];
		[collector startCollectingWithCallback:@selector(changedEntryCollectorDidFinish:) collectionDelegate:self];
		[collector autorelease];
	}
}

- (void)addedEntryCollectorDidFinish:(SimplenoteEntryCollector *)collector {
	NSArray *newNotes = [self _notesWithEntries:[collector entriesCollected]];
	
	if ([newNotes count]) {
		[delegate syncSession:self receivedAddedNotes:newNotes];		
	}
	
	[self _unregisterCollector:collector];
}
- (void)changedEntryCollectorDidFinish:(SimplenoteEntryCollector *)collector {
	
	//use the corresponding "NoteObject" keys to modify the original notes appropriately,
	//building a new array that documents our efforts
	
	NSArray *entries = [collector entriesCollected];
	NSMutableArray *changedNotes = [NSMutableArray arrayWithCapacity:[entries count]];
		
	NSUInteger i = 0;
	for (i=0; i<[entries count]; i++) {
		NSDictionary *info = [entries objectAtIndex:i];
		if ([[info objectForKey:@"deleted"] intValue]) {
			NSLog(@"entry %@ was deleted between getting the index and getting the note! it will be handled in the next sync.", info);
			continue;
		}
		NoteObject *aNote = [info objectForKey:@"NoteObject"];
		
		[self suppressPushingForNotes:[NSArray arrayWithObject:aNote]];
		
		//ignore this update if we were just about to update this note ourselves
		//allow Simplenote to perform merging based on the mod dates / version numbers
		//if this were a different service some form of merging or user-alerting might occur here
		if (![unsyncedServiceNotes containsObject:aNote]) {
			
			//get the new title and body from the content:
			NSUInteger bodyLoc = 0;
			NSString *separator = nil;
			NSString *combinedContent = [info objectForKey:@"content"];
			NSString *newTitle = [combinedContent syntheticTitleAndSeparatorWithContext:&separator newBodyAtLocation:&bodyLoc];
			
			[aNote updateWithSyncBody:[combinedContent substringFromIndex:bodyLoc] andTitle:newTitle];
			
			NSNumber *modNum = [info objectForKey:@"modify"];
			NSLog(@"updating mod time for note %@ to %@", aNote, modNum);
			[aNote setDateModified:[modNum doubleValue]];
			[aNote setSyncObjectAndKeyMD:[NSDictionary dictionaryWithObjectsAndKeys:modNum, @"modify", separator, SimplenoteSeparatorKey, nil] 
							  forService:SimplenoteServiceName];
			[changedNotes addObject:aNote];
		}
		[self stopSuppressingPushingForNotes:[NSArray arrayWithObject:aNote]];
	}
	
	if ([changedNotes count]) {
		[delegate syncSession:self didModifyNotes:changedNotes];
	}
	
	[self _unregisterCollector:collector];
}
//(don't need a deletedEntryCollectorDidFinish: method because we never request deleted notes' contents)


- (void)addedEntriesToMergeCollectorDidFinish:(SimplenoteEntryCollector *)collector {
	
	//respond to delegate with a combination of -syncSession:didModifyNotes: and -syncSession:receivedAddedNotes:

	//serverNotes and entriesCollected should be parallel arrays
//	NSArray *serverNotes = [self _notesWithEntries:[collector entriesCollected]];
	NSArray *localNotes = [collector representedObject];
	NSAssert([localNotes isKindOfClass:[NSArray class]], @"list of locally-added notes must be an array!");

	//localnotes have no keys, servernotes have keys; match them together by building a dictionary of content-hashes -> notes
	
	//update localNotes in place with keys and mod times
	
	//handle any notes-to-merge from -[collector representedObject]:
	//remove from notes-to-merge any objs whose combinedContent matches what we fetched into newNotes
	//automatically upload the rest of the unique notes using -startCreatingNotes:
	//[self startCreatingNotes:[self _uniqueNotesToMerge:[collector representedObject] comparedWithNotesOnServer:newNotes]];
	
	//what about handling notes that encountered errors while downloading (entriesInError)? those will potentially be duplicated.
	
	
	[self _unregisterCollector:collector];
}

- (NSArray*)_notesWithEntries:(NSArray*)entries {
	NSMutableArray *newNotes = [NSMutableArray arrayWithCapacity:[entries count]];
	NSUInteger i = 0;
	for (i=0; i<[entries count]; i++) {
		NSDictionary *info = [entries objectAtIndex:i];
		NSAssert(![info objectForKey:@"NoteObject"], @"this note is supposed to be new!");
		
		NSString *fullContent = [info objectForKey:@"content"];
		NSUInteger bodyLoc = 0;
		NSString *separator = nil;
		NSString *title = [fullContent syntheticTitleAndSeparatorWithContext:&separator bodyLoc:&bodyLoc oldTitle:nil];
		NSString *body = [fullContent substringFromIndex:bodyLoc];
		//get title and body, incl. separator
		NSMutableAttributedString *attributedBody = [[[NSMutableAttributedString alloc] initWithString:body attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]] autorelease];
		[attributedBody addLinkAttributesForRange:NSMakeRange(0, [attributedBody length])];
		
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:attributedBody title:title uniqueFilename:nil format:SingleDatabaseFormat];
		if (note) {
			NSNumber *modNum = [info objectForKey:@"modify"];
			[note setDateAdded:[[info objectForKey:@"create"] doubleValue]];
			[note setDateModified:[modNum doubleValue]];
			//also set mod time, key, and sepWCtx for this note's syncServicesMD
			[note setSyncObjectAndKeyMD:[NSDictionary dictionaryWithObjectsAndKeys:modNum, @"modify", 
										 [info objectForKey:@"key"], @"key", separator, SimplenoteSeparatorKey, nil] 
							 forService:SimplenoteServiceName];
			
			[newNotes addObject:note];
			[note release];
		}
	}

	return newNotes;
}


- (void)_registerCollector:(SimplenoteEntryCollector*)collector {
	[collectorsInProgress addObject:collector];
	[delegate syncSessionProgressStarted:self];
}

- (void)_unregisterCollector:(SimplenoteEntryCollector*)collector {
	
	[collectorsInProgress removeObject:[[collector retain] autorelease]];
	
	if (![collector collectionStoppedPrematurely] && [[collector entriesInError] count] && ![[collector entriesCollected] count]) {
		//failed! all failed!
		[self _stoppedWithErrorString:[NSString stringWithFormat:NSLocalizedString(@"%@ %u note(s) failed", @"e.g., Downloading 2 note(s) failed"), 
									   [collector localizedActionDescription], [[collector entriesToCollect] count]]];
	} else {
		
		if ([self isRunning]) {
			[self _updateSyncTime];
		} else {
			[self _stoppedWithErrorString:nil];
		}
	}
}

//uses nscountedset to require the number of stopSuppressing messages 
//sent for each note to match the number of suppress ones:

- (void)suppressPushingForNotes:(NSArray*)notes {
	[notesToSuppressPushing addObjectsFromArray:notes];
}
- (void)stopSuppressingPushingForNotes:(NSArray*)notes {
	[notesToSuppressPushing minusSet:[NSSet setWithArray:notes]];
}

- (NSInvocation*)_popNextInvocationForNote:(id<SynchronizedNote>)aNote {
	NSString *uuidStr = [NSString uuidStringWithBytes:*[aNote uniqueNoteIDBytes]];

	NSMutableArray *invocations = [queuedNoteInvocations objectForKey:uuidStr];
	if (!invocations) return nil;
	
	NSAssert([invocations count] != 0, @"invocations array is empty!");
	
	NSInvocation *invocation = [[invocations objectAtIndex:0] retain];
	[invocations removeObjectAtIndex:0];
	
	if (![invocations count]) {
		//this was the last queued invocation for aNote; dispose of up the array
		[queuedNoteInvocations removeObjectForKey:uuidStr];
	}
	return [invocation autorelease];
}

- (void)_queueInvocation:(NSInvocation*)anInvocation forNote:(id<SynchronizedNote>)aNote {
	if (!queuedNoteInvocations) queuedNoteInvocations = [[NSMutableDictionary alloc] init];
	NSString *uuidStr = [NSString uuidStringWithBytes:*[aNote uniqueNoteIDBytes]];
	NSMutableArray *invocations = [queuedNoteInvocations objectForKey:uuidStr];
	if (!invocations) {
		//note has no already-waiting invocations
		[queuedNoteInvocations setObject:(invocations = [NSMutableArray array]) forKey:uuidStr];
	}
	
	NSAssert(invocations != nil, @"where is the invocations array?");
	[invocations addObject:anInvocation];
	NSLog(@"queued invocation for note %@, yielding %@", aNote, invocations);
}

- (void)_modifyNotes:(NSArray*)notes withOperation:(SEL)opSEL {
	if (![notes count]) {
		//NSLog(@"not doing %s because no notes specified", opSEL);
		return;
	}
	

	if (!authToken) {
		InvocationRecorder *invRecorder = [InvocationRecorder invocationRecorder];
		[[invRecorder prepareWithInvocationTarget:self] _modifyNotes:notes withOperation:opSEL];
		[[self loginFetcher] startWithSuccessInvocation:[invRecorder invocation]];
	} else {
		
		//ensure that remote mutation does not occur more than once for the same note(s) before the callback completes
		NSMutableArray *currentlyIdleNotes = [[notes mutableCopy] autorelease];
		[currentlyIdleNotes removeObjectsInArray:[notesBeingModified allObjects]];
		
		//get the notes currently progress that we need to queue:
		NSMutableSet *reundantNotes = [notesBeingModified setIntersectedWithSet:[NSSet setWithArray:notes]];
		
		//a note does not need to be created more than once; check for this explicitly and don't re-queue those
		if (@selector(fetcherForCreatingNote:) != opSEL) {
			NSEnumerator *enumerator = [reundantNotes objectEnumerator];
			id <SynchronizedNote> noteToQueue = nil;
			while ((noteToQueue = [enumerator nextObject])) {
				InvocationRecorder *invRecorder = [InvocationRecorder invocationRecorder];
				[[invRecorder prepareWithInvocationTarget:self] _modifyNotes:[NSArray arrayWithObject:noteToQueue] withOperation:opSEL];
				[self _queueInvocation:[invRecorder invocation] forNote:noteToQueue];
			}
			
		} else if ([reundantNotes count]) {
			NSLog(@"not requeuing %@ for creation", reundantNotes);
		}
		
		//mark the notes we're about to process as being in progress
		[notesBeingModified addObjectsFromArray:currentlyIdleNotes];
		
		if ([currentlyIdleNotes count]) {
			NSLog(@"%s(%@)", opSEL, currentlyIdleNotes);
			//now actually start processing those notes
			SimplenoteEntryModifier *modifier = [[SimplenoteEntryModifier alloc] initWithEntries:currentlyIdleNotes operation:opSEL authToken:authToken email:emailAddress];
			SEL callback = (@selector(fetcherForCreatingNote:) == opSEL ? @selector(entryCreatorDidFinish:) :
							(@selector(fetcherForUpdatingNote:) == opSEL ? @selector(entryUpdaterDidFinish:) : 
							(@selector(fetcherForDeletingNote:) == opSEL ? @selector(entryDeleterDidFinish:) : NULL) ));
			
			[self _registerCollector:modifier];
			[modifier startCollectingWithCallback:callback collectionDelegate:self];
			[modifier autorelease];
		}
	}
}

- (void)startCreatingNotes:(NSArray*)notes {
	[self _modifyNotes:notes withOperation:@selector(fetcherForCreatingNote:)];
}
- (void)startModifyingNotes:(NSArray*)notes {
	[self _modifyNotes:notes withOperation:@selector(fetcherForUpdatingNote:)];	
}
- (void)startDeletingNotes:(NSArray*)notes {
	[self _modifyNotes:notes withOperation:@selector(fetcherForDeletingNote:)];
}

- (void)_finishModificationsFromModifier:(SimplenoteEntryModifier *)modifier {
	
	NSMutableArray *finishedNotes = [[[[modifier entriesCollected] objectsFromDictionariesForKey:@"NoteObject"] mutableCopy] autorelease];
	[finishedNotes addObjectsFromArray:[[modifier entriesInError] objectsFromDictionariesForKey:@"NoteObject"]];
	
	[notesBeingModified minusSet:[NSSet setWithArray:finishedNotes]];
	
	NSUInteger i = 0;
	for (i=0; i<[finishedNotes count]; i++) {
		//start any subsequently queued invocations for the notes that just finished being remotely modified
		NSInvocation *invocation = [self _popNextInvocationForNote:[finishedNotes objectAtIndex:i]];
		if (invocation) NSLog(@"popped invocation %@ for %@", invocation, [finishedNotes objectAtIndex:i]);
		[invocation invoke];
	}
	
	[self _unregisterCollector:modifier];
	
	//perhaps entriesInError should be re-queued? (except for 404-deletions)
	
	if ([[modifier entriesCollected] count]) [delegate syncSessionDidFinishRemoteModifications:self];
}

- (void)entryCreatorDidFinish:(SimplenoteEntryModifier *)modifier {
	//our inserts have been remotely applied
	//SimplenoteEntryModifier should have taken care of adding the metadata
	[self _finishModificationsFromModifier:modifier];
}

- (void)entryUpdaterDidFinish:(SimplenoteEntryModifier *)modifier {
	//our changes have been remotely applied
	//mod times should already have been updated
	[self _finishModificationsFromModifier:modifier];
}

- (void)entryDeleterDidFinish:(SimplenoteEntryModifier *)modifier {
	//SimplenoteEntryModifier should have taken care of removing the metadata for *successful* deletions
	
	//however if the deletion resulted in a 404, ASSUME that the error was from the web application and not the web server, 
	//and thus that the note wasn't deleted because it didn't need be, so these deleted notes should also have their syncserviceMD removed 
	//to avoid repeated unsuccessful attempts at deletion. if a deletednoteobject was improperly removed, the at worst it will return on the next sync, 
	//and the user will have another opportunity to remove the note
	NSUInteger i = 0;
	for (i = 0; i<[[modifier entriesInError] count]; i++) {
		NSDictionary *info = [[modifier entriesInError] objectAtIndex:i];
		if ([[info objectForKey:@"StatusCode"] intValue] == 404) {
			NSAssert([[info objectForKey:@"NoteObject"] isKindOfClass:[DeletedNoteObject class]], @"a deleted note that generated an error is not actually a deleted note");
			[[info objectForKey:@"NoteObject"] removeAllSyncMDForService:SimplenoteServiceName];
		}
	}
	
	[self _finishModificationsFromModifier:modifier];
}


- (void)syncResponseFetcher:(SyncResponseFetcher*)fetcher receivedData:(NSData*)data returningError:(NSString*)errString {
	
	if (errString) {
		if (fetcher == listFetcher && [fetcher statusCode] == 401 && !lastIndexAuthFailed) {
			//token might have expired, and the only reason we would be asked to fetch the list would be if it were for a full sync
			//trying again should not cause a loop, unless the login method consistently returns an incorrect token
			lastIndexAuthFailed = YES;
			[self _clearAuthTokenAndDependencies];
			[self performSelector:@selector(startFetchingListForFullSync) withObject:nil afterDelay:0.0];
		}
		NSLog(@"%@ returned %@", fetcher, errString);
		
		//report error to delegate
		[self _stoppedWithErrorString:[fetcher didCancel] ? nil : errString];
		return;
	}
	NSString *bodyString = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	
	if (fetcher == loginFetcher) {
		if ([bodyString length]) {
			[authToken autorelease];
			authToken = [bodyString retain];
		} else {
			[self _stoppedWithErrorString:NSLocalizedString(@"No authorization token", @"Simplenote-specific error")];
		}
	} else if (fetcher == listFetcher) {
		
		lastIndexAuthFailed = NO;
		NSArray *rawEntries = [NSArray arrayWithJSONString:bodyString];
		
		//convert dates and "deleted" indicator into NSNumbers
		NSMutableArray *entries = [NSMutableArray arrayWithCapacity:[rawEntries count]];
		NSUInteger i = 0;
		for (i=0; i<[rawEntries count]; i++) {
			NSDictionary *rawEntry = [rawEntries objectAtIndex:i];
			
			NSString *noteKey = [rawEntry objectForKey:@"key"];
			NSString *modifiedDateString = [rawEntry objectForKey:@"modify"];
			
			if ([noteKey length] && [modifiedDateString length]) {
				//convenient intermediate format
				[entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
									noteKey, @"key", 
									[NSNumber numberWithInt:[[rawEntry objectForKey:@"deleted"] intValue]], @"deleted", 
									[NSNumber numberWithDouble:[modifiedDateString absoluteTimeFromSimplenoteDate]], @"modify", nil]];
			}
		}
		
		[self _updateSyncTime];
		[lastErrorString autorelease];
		lastErrorString = nil;
		
		[delegate syncSession:self receivedFullNoteList:entries];		
		
	} else {
		NSLog(@"unknown fetcher returned: %@, body: %@", fetcher, bodyString);
	}
}

- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}

- (id)delegate {
	return delegate;
}

- (void)dealloc {
	
	[queuedNoteInvocations release];
	[notesBeingModified release];
	[notesToSuppressPushing release];
	[unsyncedServiceNotes release];
	[emailAddress release];
	[password release];
	[authToken release];
	[listFetcher release];
	[loginFetcher release];
	[lastSyncedTime release];
	[collectorsInProgress release];
	[lastErrorString release];
	
	[super dealloc];
}

@end

