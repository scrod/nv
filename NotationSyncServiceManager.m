//
//  NotationSyncServiceManager.m
//  Notation
//
//  Created by Zachary Schneirov on 12/10/09.
//  Copyright 2009 Zachary Schneirov. All rights reserved.
//

#import "NotationSyncServiceManager.h"
#import "SyncServiceSessionProtocol.h"
#import "NotationPrefs.h"
#import "SimplenoteSession.h"

@implementation NotationController (NotationSyncServiceManager)

//these two methods must return parallel arrays:

+ (NSArray*)allServiceNames {
	static NSArray *allNames = nil;
	if (!allNames) allNames = [[NSArray alloc] initWithObjects:SimplenoteServiceName, nil];
	return allNames;
}
+ (NSArray*)allServiceClasses {
	static NSArray *allClasses = nil;
	if (!allClasses) allClasses = [[NSArray alloc] initWithObjects:NSClassFromString(@"SimplenoteSession"), nil];

	return allClasses;
}

- (id<SyncServiceSession>)sessionForSyncService:(NSString*)serviceName {
	//map names to sync service sessions, creating them if necessary
	NSAssert(serviceName != nil, @"servicename is required");
	
	if (!syncServiceSessions) syncServiceSessions = [[NSMutableDictionary alloc] initWithCapacity:1];
	
	id<SyncServiceSession> session = [syncServiceSessions objectForKey:serviceName];
	
	if ([session authorizationExpired]) {
		NSLog(@"%@ has expired; revalidating...", session);
		[self invalidateSyncServiceSession:serviceName];
		session = nil;
	}
	if (!session) {
		if ([serviceName isEqualToString:SimplenoteServiceName]) {
			
			if (![notationPrefs syncServiceIsEnabled:SimplenoteServiceName]) return nil;
			
			SimplenoteSession *snSession = [[SimplenoteSession alloc] initWithNotationPrefs:notationPrefs];
			[snSession setDelegate:self];
			
			if (snSession) [syncServiceSessions setObject:snSession forKey:serviceName];
			[snSession release]; //owned by syncServiceSessions
			return snSession;
		} /* else if ([serviceName isEqualToString:SimpletextServiceName]) {
		   
		   //init and return other services here
		   
		} */ else {
			NSLog(@"%s: unknown service named '%@'", _cmd, serviceName);
		}
	}
	return session;
}

- (void)invalidateSyncServiceSession:(NSString*)serviceName {
	[(id<SyncServiceSession>)[syncServiceSessions objectForKey:serviceName] setDelegate:nil];
	[syncServiceSessions removeObjectForKey:serviceName];
}

- (NSDictionary*)invertedDictionaryOfEntries:(NSArray*)entries keyedBy:(NSString*)keyName {
	NSUInteger i = 0;
	NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:[entries count]];
	
	for (i=0; i<[entries count]; i++) {
		NSDictionary *entry = [entries objectAtIndex:i];
		NSString *keyForService = [entry objectForKey:keyName];
		if (keyForService) {
			[dict setObject:entry forKey:keyForService];
		} else {
			NSLog(@"service key for %@ does not exist", entry);
		}
	}
	return dict;
}

- (NSDictionary*)invertedDictionaryOfNotes:(NSArray*)someNotes forSession:(id<SyncServiceSession>)aSession {
	NSUInteger i = 0;
	NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:[someNotes count]];
	NSString *keyElement = [aSession nameOfKeyElement];
	NSString *serviceName = [aSession serviceName];
	
	for (i=0; i<[someNotes count]; i++) {
		NoteObject *note = [someNotes objectAtIndex:i];
		NSDictionary *serviceDict = [[note syncServicesMD] objectForKey:serviceName];
		if (serviceDict) {
			[dict setObject:note forKey:[serviceDict objectForKey:keyElement]];
		} else {
			//NSLog(@"service key for %@ does not exist", note);
		}
	}
	return dict;
}

- (void)startSyncForAllServices {
	//sync for all _active_ services 
}

- (void)startSyncForService:(NSString*)serviceName {
	NSAssert(serviceName != nil, @"servicename is required");
	
	//request the list of notes, then compare objs when we have it
	[[self sessionForSyncService:serviceName] startFetchingListForFullSync];
}

- (void)syncSession:(id <SyncServiceSession>)syncSession receivedFullNoteList:(NSArray*)allEntries {
	
	[self makeNotesMatchList:allEntries fromSyncSession:syncSession];
}

- (void)syncSession:(id <SyncServiceSession>)syncSession receivedAddedNotes:(NSArray*)addedNotes {
	//insert these notes into the list
	//no need to "reveal" them to the user
	[syncSession suppressPushingForNotes:addedNotes];
	[self addNotesFromSync:addedNotes];
	[syncSession stopSuppressingPushingForNotes:addedNotes];
	
	//beware of adding these in response to redundant calls to -startCollectingAddedNotesWithEntries:
}

- (void)syncSession:(id <SyncServiceSession>)syncSession didModifyNotes:(NSArray*)changedNotes {
	//update the list of notes and the views as necessary
	notesChanged = YES;
	NSUInteger i = 0;
	for (i = 0; i<[changedNotes count]; i++) {
		[delegate contentsUpdatedForNote:[changedNotes objectAtIndex:i]];
	}
	[self resortAllNotes];
	[self refilterNotes];
}

- (void)syncSessionDidFinishRemoteModifications:(id <SyncServiceSession>)syncSession {
	
	//cleanup operations
	
	//we can examine the list of deleted notes in case the syncSession 
	//removed any service-specific metadata in entryDeleterDidFinish:
	[self _purgeAlreadyDistributedDeletedNotes];
}


- (void)makeNotesMatchList:(NSArray*)MDEntries fromSyncSession:(id <SyncServiceSession>)syncSession {
	NSString *keyName = [syncSession nameOfKeyElement];
	NSString *serviceName = [syncSession serviceName];
	NSUInteger i = 0, remotelyMissingCount = 0;

	NSDictionary *remoteDict = [self invertedDictionaryOfEntries:MDEntries keyedBy:keyName];
	//NSLog(@"%s: got inverted dict of entries: %@", _cmd, remoteDict);
	
	//*** get the notes that don't yet exist on the server (added locally)
	//	(if no already-synced notes exist, merge by default, and assume user was already given the chance to start fresh w/ a new DB if accounts were being changed)
	//*** get the notes that need to be sent to the server (changed-locally/already-synced); compare mod-dates	
	//### get a list of changed notes that are on the server (changed remotely)
	//### get a list of previously-synced notes that need to be deleted locally because they no longer exist on the server, or have deleted=1 (removed remotely)
	NSMutableArray *locallyAddedNotes = [NSMutableArray array];
	NSMutableArray *locallyChangedNotes = [NSMutableArray array];
	NSMutableArray *remotelyChangedNotes = [NSMutableArray array];
	NSMutableArray *remotelyDeletedNotes = [NSMutableArray array];
	for (i=0; i<[allNotes count]; i++) {
		id <SynchronizedNote>note = [allNotes objectAtIndex:i];
		NSDictionary *thisServiceInfo = [[note syncServicesMD] objectForKey:serviceName];
		if (thisServiceInfo) {
			//get corresponding note on server
			NSDictionary *remoteInfo = [remoteDict objectForKey:[thisServiceInfo objectForKey:keyName]];
			if (remoteInfo) {
				//this note already exists on the server -- check for modifications from either direction
				if (![syncSession remoteEntryWasMarkedDeleted:remoteInfo]) {
					
					NSComparisonResult changeDiff = [syncSession localEntry:thisServiceInfo isNewerThanRemoteEntry:remoteInfo];
					if (changeDiff == NSOrderedDescending) {
						//this note is newer than its counterpart on the server; it should be uploaded eventually
						//this would happen because another client set an older modification date when updating OR
						//we set its syncServicesMD modification date manually because the note changed and is now actually newer
						
						//XXX need to verify GMT conversions XXX
						[locallyChangedNotes addObject:note];
					} else if (changeDiff == NSOrderedAscending) {
						[remotelyChangedNotes addObject:note];
					}
				} else {
					//this note was marked deleted on the server and will soon be removed by the iPhone app; we can safely remote it -- RIGHT?
					[remotelyDeletedNotes addObject:note];
				}
			} else {
				//this note _was_ synced, but is no longer on the server; it was _probably_ deleted--that or simplenote is glitching
				//if all notes end up here, pass control to -handleSyncingWithAllMissingAndRemoteNoteCount:fromSession:
				remotelyMissingCount++;
				[remotelyDeletedNotes addObject:note];
			}
		} else {
			//this note was not synced (or it's intended to be merged), so prepare it for uploading
			[locallyAddedNotes addObject:note];
		}
	}
	
	//*** get the notes that need to be deleted from the server (deletedNotes set) (removed-locally/already-synced)
	NSMutableArray *locallyDeletedNotes = [NSMutableArray arrayWithCapacity:[deletedNotes count]];
	NSArray *deletedNotesArray = [deletedNotes allObjects];
	for (i=0; i<[deletedNotesArray count]; i++) {
		id <SynchronizedNote>note = [deletedNotesArray objectAtIndex:i];
		NSDictionary *thisServiceInfo = [[note syncServicesMD] objectForKey:serviceName];
		if (thisServiceInfo) {
			//find deleted notes of which this service hasn't yet been notified (e.g., deleted notes that still have an entry for this service)
			[locallyDeletedNotes addObject:note];
		}
	}
	
	
	//### get a list of new notes on the server (added remotely)
	NSMutableArray *remotelyAddedEntries = [NSMutableArray array];
	NSDictionary *localNotesDict = [self invertedDictionaryOfNotes:allNotes forSession:syncSession];
	NSDictionary *localDeletedNotesDict = [self invertedDictionaryOfNotes:locallyDeletedNotes forSession:syncSession];
	
	for (i=0; i<[MDEntries count]; i++) {
		NSDictionary *remoteEntry = [MDEntries objectAtIndex:i];
		//a note with this sync-key for this service does not exist
		NSString *remoteKey = [remoteEntry objectForKey:keyName];
		if ([remoteKey length]) {
			//check if a remote note doesn't exist in allNotes, and guard against
			//the note being removed before the delete op could be pushed
			if (![localNotesDict objectForKey:remoteKey] && ![localDeletedNotesDict objectForKey:remoteKey]) {
				if (![syncSession remoteEntryWasMarkedDeleted:remoteEntry]) {
					[remotelyAddedEntries addObject:remoteEntry];
				} else {
					//look! it's a note that was remotely added and then remotely deleted before we ever had a chance to sync!
					//if we were the ones who deleted it, then it could still exist in deletedNotes set, but that's just to notify other services
				}
			}
		} else {
			NSLog(@"Hmm! remote entry %@ has no key", remoteEntry);
		}
	}
	
	//show this only if there is no evidence of these notes ever being on the server (all remotely removed with none manually deleted)
	if (remotelyMissingCount && [allNotes count] == remotelyMissingCount && [remotelyDeletedNotes count] == remotelyMissingCount) {
		if ([self handleSyncingWithAllMissingAndRemoteNoteCount:[remotelyAddedEntries count] fromSession:syncSession]) {
			return;
		}
	}
	
	//if locallyAdded count == allNotes count; e.g., if this is a first sync or merge of this database with this service account, 
	//then download remotelyAddedEntries first so that duplicates can be merged with locallyAddedNotes 
	//only those locallyAddedNotes with unique combinedContent strings will be uploaded
	
	//hope the server doesn't mind us doing all this in parallel
	
	//POST these entries to the server, with the assumption that the dates in syncServiceMD are set already
	NSLog(@"locally added notes: %@", locallyAddedNotes);
	//postpone this if we have notes to merge
	[syncSession startCreatingNotes:locallyAddedNotes];
	//ensure the DB is flushed in preparation for syncing metadata that might be added to locallyAddedNotes
	if ([locallyAddedNotes count]) notesChanged = YES;
	
	NSLog(@"locally changed notes: %@", locallyChangedNotes);
	[syncSession startModifyingNotes:locallyChangedNotes];
	
	//upon success, make sure that in deletedNotes set this syncService-dict is removed
	NSLog(@"locally deleted notes: %@", locallyDeletedNotes);
	[syncSession startDeletingNotes:locallyDeletedNotes];
	
	//--
	//any DB modifications that will trigger a push must be wrapped in suppress messages to the service
	//for added notes, this is done in the callback before actually adding them to allNotes
	//for updated notes this is done by the session itself, as it does the updating itself
	//for removed notes this is done below, right before actually removing them from allNotes
	
	//collect these entries from server and add/modify the existing notes with the results
	NSLog(@"remotely added entries: %@", remotelyAddedEntries);
	[syncSession startCollectingAddedNotesWithEntries:remotelyAddedEntries mergingWithNotes:nil];
	
	NSLog(@"remotely changed notes: %@", remotelyChangedNotes);
	[syncSession startCollectingChangedNotesWithEntries:remotelyChangedNotes];
	
	
	//remotelyDeletedNotes should be deleted from the DB; add to deletedNotes but without this syncService-dict (For syncing the deletion back to other services)
	NSLog(@"remotely deleted notes: %@", remotelyDeletedNotes);
	
	[remotelyDeletedNotes makeObjectsPerformSelector:@selector(removeAllSyncMDForService:) withObject:serviceName];
	
	[syncSession suppressPushingForNotes:remotelyDeletedNotes];
	if ([remotelyDeletedNotes count])
		[self removeNotes:remotelyDeletedNotes]; //will register in the undo handle
	[syncSession stopSuppressingPushingForNotes:remotelyDeletedNotes];
	
		
}


- (void)schedulePushToAllSyncServicesForNote:(id <SynchronizedNote>)aNote {
	NSArray *svcs = [[self class] allServiceNames];
	NSUInteger i = 0;
	for (i=0; i<[svcs count]; i++) {
		id <SyncServiceSession> session = [self sessionForSyncService:[svcs objectAtIndex:i]];
		[session schedulePushForNote:aNote];
	}
}

- (void)syncSettingsChangedForService:(NSString*)serviceName {

	//reset credentials
	[self invalidateSyncServiceSession:serviceName];
	
	//reset timer
	
	
	//but don't resync here; only prepare for the next sync
}

- (BOOL)handleSyncingWithAllMissingAndRemoteNoteCount:(NSUInteger)foundNotes fromSession:(id <SyncServiceSession>)aSession {
	
	if ([allNotes count] < 2) {
		//this would be a nuisance
		return NO;
	}
	
	NSString *serviceTitle = [aSession localizedServiceTitle];
	NSString *serviceName = [aSession serviceName];
	
	//before we make any changes on either side, check to see if this is the all-new/all-missing case (e.g., different account or terrible server crash)
	//give the user a chance to force a merge, replace the notes, or disable syncing
	//if the first, cancel this sync, remove all metadata for this service, and restart sync
	
	//if foundNotes == 0, use a slightly different message -- maybe
	
	NSInteger res = NSAlertDefaultReturn;
	
	if (!foundNotes) {
		res = NSRunCriticalAlertPanel([NSString stringWithFormat:NSLocalizedString(@"The %@ server reports that no notes exist. Delete all %u notes in Notational Velocity to match it, or re-upload them now?", nil), serviceTitle, [allNotes count]],
									  [NSString stringWithFormat:NSLocalizedString(@"If your %@ account is different, you may prefer to create a new database in Notational Velocity instead.", nil), serviceTitle],
									  [NSString stringWithFormat:NSLocalizedString(@"Turn Off Syncing", @"default button in the dialog above"), serviceTitle], 
									  NSLocalizedString(@"Re-upload Notes", @"dialog button for uploading local notes when none exist remotely"), 
									  NSLocalizedString(@"Remove All Notes", @"dialog button for deleting all notes when none exist remotely"));
	} else {
		res = NSRunCriticalAlertPanel([NSString stringWithFormat:NSLocalizedString(@"The %@ server holds a completely different set of notes. Replace all %u notes in Notational Velocity with the %u notes on the server, or merge both sets together?", nil), 
									   serviceTitle, [allNotes count], foundNotes],
									  [NSString stringWithFormat:NSLocalizedString(@"Replacing will remove all %u notes from Notational Velocity. Merging will cause up to %u notes to be added to %@.", nil), 
									   [allNotes count], [allNotes count], serviceTitle],
									  [NSString stringWithFormat:NSLocalizedString(@"Turn Off Syncing", @"default button in the dialog above"), serviceTitle], 
									  NSLocalizedString(@"Merge Notes", @"dialog button for uploading local notes"), 
									  NSLocalizedString(@"Replace All Notes", @"dialog button for deleting all notes"));
	}
	switch (res) {
		case NSAlertDefaultReturn: //disable this sync service
			[aSession stop];
			[self invalidateSyncServiceSession:serviceName];
			[notationPrefs setSyncEnabled:NO forService:serviceName];
			//should not need this; sync prefs should have their own control center:
			[[NSNotificationCenter defaultCenter] postNotificationName:SyncPrefsDidChangeNotification object:nil];
			
			return YES;
		case NSAlertOtherReturn: //replace notes
			//continue along down your potentially dangerous path
			NSLog(@"User agreed to replace all notes with those from the server");
			
			return NO;
		case NSAlertAlternateReturn: //merge notes
			//remove sync metadata and restart sync
			[aSession stop];
			[allNotes makeObjectsPerformSelector:@selector(removeAllSyncMDForService:) withObject:serviceName];
			
			[(id)aSession performSelector:@selector(startFetchingListForFullSync) withObject:nil afterDelay:0.0];
			
			return YES;
	}
	
	NSLog(@"%s: unhandled case (res: %d)!", _cmd, res);
	return YES;
}

@end




