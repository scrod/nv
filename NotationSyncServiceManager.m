//
//  NotationSyncServiceManager.m
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


#import "NotationSyncServiceManager.h"
#import "SyncServiceSessionProtocol.h"
#import "SyncSessionController.h"
#import "NotationPrefs.h"

@implementation NotationController (NotationSyncServiceManager)


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
	NSString *keyElement = [[aSession class] nameOfKeyElement];
	NSString *serviceName = [[aSession class] serviceName];
	
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

- (void)startSyncServices {
	[syncSessionController setSyncDelegate:self];
	[syncSessionController initializeAllServices];
}

- (void)stopSyncServices {
	[NSObject cancelPreviousPerformRequestsWithTarget:syncSessionController];	
	[syncSessionController unregisterPowerChangeCallback];
	[syncSessionController invalidateAllServices];
	[syncSessionController setSyncDelegate:nil];
}

- (void)syncSessionProgressStarted:(id <SyncServiceSession>)syncSession {
	//set sync pulldown menu status icon
	[syncSessionController queueStatusNotification];
	//[delegate syncStatusShouldUpdateToShowProgress:YES error:NO];
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
	NSString *keyName = [[syncSession class] nameOfKeyElement];
	NSString *serviceName = [[syncSession class] serviceName];
	NSUInteger i = 0;

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
	NSMutableArray *remotelyMissingNotes = [NSMutableArray array];
	
	for (i=0; i<[allNotes count]; i++) {
		id <SynchronizedNote>note = [allNotes objectAtIndex:i];
		NSDictionary *thisServiceInfo = [[note syncServicesMD] objectForKey:serviceName];
		if (thisServiceInfo) {
			//get corresponding note on server
			NSDictionary *remoteInfo = [remoteDict objectForKey:[thisServiceInfo objectForKey:keyName]];
			if (remoteInfo) {
				//this note already exists on the server -- check for modifications from either direction
				NSComparisonResult changeDiff = [syncSession localEntry:thisServiceInfo compareToRemoteEntry:remoteInfo];
				
				if (![syncSession remoteEntryWasMarkedDeleted:remoteInfo]) {
					if (changeDiff == NSOrderedDescending) {
						//this note is newer than its counterpart on the server; it should be uploaded eventually
						//this would happen because another client set an older modification date when updating OR
						//we set its syncServicesMD modification date manually because the note changed and is now actually newer
						
						//XXX need to verify GMT conversions XXX
						[locallyChangedNotes addObject:note];
					} else if (changeDiff == NSOrderedAscending) {
						[remotelyChangedNotes addObject:note];
					}
				} else if (changeDiff != NSOrderedDescending) {
					//nah ah ah, a delete should not stick if local mod time is newer! otherwise local changes will be lost
					
					//this note was marked deleted on the server and will soon be removed by the iPhone app; we can safely remote it -- RIGHT?
					[remotelyDeletedNotes addObject:note];
				} else {
					//undoing delete of this entry because it was subsequently updated locally;
					//this happens naturally when one-way pushing, so a full sync should be consistent with that behavior
					[locallyChangedNotes addObject:note];
				}
			} else {
				//this note _was_ synced, but is no longer on the server; it was _probably_ deleted--that or simplenote is glitching
				//if all notes end up here, pass control to -handleSyncingWithAllMissingAndRemoteNoteCount:fromSession:
				[remotelyMissingNotes addObject:note];
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
			//but if a note has been modified remotely, will we delete it and then redownload it?
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
			
			//can't find the note in allNotes; it might be new!
			if (![localNotesDict objectForKey:remoteKey]) {
				if (![syncSession remoteEntryWasMarkedDeleted:remoteEntry]) {
					
					//check if a remote note doesn't exist in allNotes, and guard against
					//the note being removed before the delete op could be pushed
					
					//however if remoteEntry is _newer_ than the note in localDeletedNotesDict, then it should undo the deletion locally
					//by allowing the entry to be added to remotelyAddedEntries and short-circuiting remote removal of the deleted note
					
					id <SynchronizedNote> ldn = [localDeletedNotesDict objectForKey:remoteKey];
					if (ldn && [syncSession localEntry:[[ldn syncServicesMD] objectForKey:serviceName] compareToRemoteEntry:remoteEntry] == NSOrderedAscending) {
						//NSLog(@"%@ was modified on the server after being deleted locally; restoring it", remoteEntry);
						//don't delete this note on the server, and anonymize its metadata to allow it to be purged
						[locallyDeletedNotes removeObject:ldn];
						[ldn removeAllSyncMDForService:serviceName];
						notesChanged = YES;
					} else if (ldn) {
						//NSLog(@"%@ was modified locally and subsequently deleted locally, or simply deleted locally, so not adding to remotelyAddedEntries", remoteEntry);
						continue;
					}
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
	if ([remotelyMissingNotes count] && [allNotes count] == ([remotelyMissingNotes count] + [locallyAddedNotes count])) {
		if ([self handleSyncingWithAllMissingAndRemoteNoteCount:[remotelyAddedEntries count] fromSession:syncSession]) {
			goto ended;
		}
	}
	
	NSArray *mergeNotes = nil;
	
	//follow the user's previous wishes to merge:, either from a previous invocation of handleSyncingWithAllMissingAndRemoteNoteCount: or from the alert below
	BOOL wasToldToMerge = [notationPrefs syncNotesShouldMergeForServiceName:serviceName];
	
	//if this is a first sync or merge of this database with this service account, 
	//then download remotelyAddedEntries first so that duplicates can be merged with locallyAddedNotes 
	//only those locallyAddedNotes with unique combinedContent strings will be uploaded
	//this occurs via startCollectingAddedNotesWithEntries:mergingWithNotes:
	if ([locallyAddedNotes count] && ([locallyAddedNotes count] == [allNotes count] || wasToldToMerge)) {	
		if ([allNotes count] > 1 && !wasToldToMerge) {
			if (NSRunAlertPanel([NSString stringWithFormat:NSLocalizedString(@"Add %u existing notes in the database to %@?", nil), 
								 [allNotes count], [[syncSession class] localizedServiceTitle]],
								NSLocalizedString(@"Notes will be merged, omitting entries duplicated on the server.", nil), 
								NSLocalizedString(@"Add Notes", nil), NSLocalizedString(@"Turn Off Syncing", nil), nil) == NSAlertAlternateReturn) {
				[syncSessionController disableService:serviceName];
				goto ended;
			} else {
				//remember that we have to merge them for next time in case sync is cancelled; do not remember "automatic" merges
				[notationPrefs setSyncShouldMerge:YES inCurrentAccountForService:serviceName];
			}
		}
		if (wasToldToMerge) NSLog(@"continuing previous merge");
		mergeNotes = locallyAddedNotes;
	} else if (![locallyAddedNotes count]) {
		//once all the locally-added notes have been taken care of, future syncs should not continue to merge
		[notationPrefs setSyncShouldMerge:NO inCurrentAccountForService:serviceName];
	}
	
	if ([locallyAddedNotes count] || [locallyChangedNotes count] || [locallyDeletedNotes count] || [mergeNotes count] || 
		[remotelyAddedEntries count] || [remotelyChangedNotes count] || [remotelyDeletedNotes count] || [remotelyMissingNotes count]) {
		NSLog(@"local: %u added, %u changed, %u deleted, %u to merge", 
			  [locallyAddedNotes count], [locallyChangedNotes count], [locallyDeletedNotes count], [mergeNotes count]);
		NSLog(@"remote: %u added, %u changed, %u deleted, %u missing", 
			  [remotelyAddedEntries count], [remotelyChangedNotes count], [remotelyDeletedNotes count], [remotelyMissingNotes count]);
	}

	//POST these entries to the server, with the assumption that the dates in syncServiceMD are set already
	//postpone this if we have notes to merge (and there are locally added entries to trigger that merge by DLing)
	if (!([mergeNotes count] && [remotelyAddedEntries count])) 
		[syncSession startCreatingNotes:locallyAddedNotes];
	else
		NSLog(@"not creating notes because %u mergenotes exist", [mergeNotes count]);
	
	[syncSession startModifyingNotes:locallyChangedNotes];
	
	//upon success, make sure that in deletedNotes set this syncService-dict is removed
	[syncSession startDeletingNotes:locallyDeletedNotes];

	
	//collect these entries from server and add/modify the existing notes with the results
	[syncSession startCollectingAddedNotesWithEntries:remotelyAddedEntries mergingWithNotes:mergeNotes];
	
	[syncSession startCollectingChangedNotesWithEntries:remotelyChangedNotes];
	
	//remotelyMissing and remotelyDeleted should be removed from the DB; we must remove syncMD to ensure note is not repeatedly-deleted
	//for remotelyMissing, remove syncService-dict before registering w/undo handler to force re-creation in case of undo
	[remotelyMissingNotes makeObjectsPerformSelector:@selector(removeAllSyncMDForService:) withObject:serviceName];
	
	NSMutableArray *remotelyMissingAndDeletedNotes = [[remotelyMissingNotes mutableCopy] autorelease];
	[remotelyMissingAndDeletedNotes addObjectsFromArray:remotelyDeletedNotes];
	
	[syncSession suppressPushingForNotes:remotelyMissingAndDeletedNotes];
	if ([remotelyMissingAndDeletedNotes count]) [self removeNotes:remotelyMissingAndDeletedNotes];
	[syncSession stopSuppressingPushingForNotes:remotelyMissingAndDeletedNotes];

	//for remotelyDeletedNotes, also remove syncMD from deletedNotes, but leave syncMD will be left in the undo-registered notes 
	[self removeSyncMDFromDeletedNotesInSet:[NSSet setWithArray:remotelyDeletedNotes] forService:serviceName];
	
ended:
	//we might not be continuing with the sync, in which case we wouldn't get a 'stop' message
	//so do things conditionally that otherwise might have been done when stopping
	[syncSessionController performSelector:@selector(invokeUncommmitedWaitCallbackIfNecessaryReturningError:) withObject:nil afterDelay:0];
	[syncSessionController queueStatusNotification];
}

- (void)syncSession:(id <SyncServiceSession>)syncSession didStopWithError:(NSString*)errString {
	
	[syncSessionController performSelector:@selector(invokeUncommmitedWaitCallbackIfNecessaryReturningError:) withObject:errString afterDelay:0];
	//if there was an error, the session would remember it and the sessioncontroller would report it when building the status menu
	[syncSessionController queueStatusNotification];
}

- (void)schedulePushToAllSyncServicesForNote:(id <SynchronizedNote>)aNote {
	[syncSessionController schedulePushToAllInitializedSessionsForNote:aNote];
}

- (void)syncSettingsChangedForService:(NSString*)serviceName {

	//reset credentials
	[syncSessionController invalidateSyncService:serviceName];
	
	//reset timer and prepare for the next sync
	[NSObject cancelPreviousPerformRequestsWithTarget:syncSessionController selector:@selector(initializeService:) object:serviceName];
	[syncSessionController performSelector:@selector(initializeService:) withObject:serviceName afterDelay:2];
	
}

- (BOOL)handleSyncingWithAllMissingAndRemoteNoteCount:(NSUInteger)foundNotes fromSession:(id <SyncServiceSession>)aSession {
	
	if ([allNotes count] < 2) {
		//this would be a nuisance
		return NO;
	}
	
	NSString *serviceTitle = [[aSession class] localizedServiceTitle];
	NSString *serviceName = [[aSession class] serviceName];
	
	//before we make any changes on either side, check to see if this is the all-new/all-missing case (e.g., different account or terrible server crash)
	//give the user a chance to force a merge, replace the notes, or disable syncing
	//if the first, cancel this sync, remove all metadata for this service, and restart sync
	
	//if foundNotes == 0, use a slightly different message -- maybe
	
	NSInteger res = NSAlertDefaultReturn;
	
	if (!foundNotes) {
		res = NSRunCriticalAlertPanel([NSString stringWithFormat:NSLocalizedString(@"The %@ server reports that no notes exist. Delete all %u notes in Notational Velocity to match it, or re-upload them now?", nil), serviceTitle, [allNotes count]],
									  [NSString stringWithFormat:NSLocalizedString(@"If your %@ account is different, you may prefer to create a new database in Notational Velocity instead.", nil), serviceTitle],
									  [NSString stringWithFormat:NSLocalizedString(@"Turn Off Syncing", nil), serviceTitle], 
									  NSLocalizedString(@"Re-upload Notes", @"dialog button for uploading local notes when none exist remotely"), 
									  NSLocalizedString(@"Remove All Notes", @"dialog button for deleting all notes when none exist remotely"));
	} else {
		res = NSRunCriticalAlertPanel([NSString stringWithFormat:NSLocalizedString(@"The %@ server holds a different set of notes. Replace all %u notes in Notational Velocity with the %u notes on the server, or merge both sets together?", nil), 
									   serviceTitle, [allNotes count], foundNotes],
									  [NSString stringWithFormat:NSLocalizedString(@"Replacing will remove all %u notes from Notational Velocity. Merging will upload all notes to %@, omitting duplicates.", nil), 
									   [allNotes count], serviceTitle],
									  [NSString stringWithFormat:NSLocalizedString(@"Turn Off Syncing", nil), serviceTitle], 
									  NSLocalizedString(@"Merge Notes", @"dialog button for uploading local notes"), 
									  NSLocalizedString(@"Replace All Notes", @"dialog button for deleting all notes"));
	}
	switch (res) {
		case NSAlertDefaultReturn:
			[syncSessionController disableService:serviceName];
			return YES;
		case NSAlertAlternateReturn: //merge notes
			
			[undoManager removeAllActions];
			
			//remove sync metadata and restart sync
			[aSession stop];
			[allNotes makeObjectsPerformSelector:@selector(removeAllSyncMDForService:) withObject:serviceName];
			[notationPrefs setSyncShouldMerge:YES inCurrentAccountForService:serviceName];
			notesChanged = YES;
			
			[(id)aSession performSelector:@selector(startFetchingListForFullSyncManual) withObject:nil afterDelay:0.0];
			
			return YES;
		case NSAlertOtherReturn: //replace notes
			//undoing past this point can create much confusion for the user
			[undoManager removeAllActions];
			
			[notationPrefs setSyncShouldMerge:NO inCurrentAccountForService:serviceName];
			//continue along down your potentially dangerous path
			NSLog(@"User agreed to replace all notes with those from the server");
			
			return NO;			
	}
	
	NSLog(@"%s: unhandled case (res: %d)!", _cmd, res);
	return YES;
}

@end


