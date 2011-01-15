//
//  SyncServiceSession.h
//  Notation
//
//  Created by Zachary Schneirov on 12/12/09.

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


#import <Cocoa/Cocoa.h>

#import "SynchronizedNoteProtocol.h"

@class SyncResponseFetcher;
@class NotationPrefs;

@protocol SyncServiceSession <NSObject>

+ (NSString*)localizedServiceTitle;
+ (NSString*)serviceName;
+ (NSString*)nameOfKeyElement;

- (id)initWithNotationPrefs:(NotationPrefs*)prefs;

- (NSComparisonResult)localEntry:(NSDictionary*)localEntry compareToRemoteEntry:(NSDictionary*)remoteEntry;
- (BOOL)remoteEntryWasMarkedDeleted:(NSDictionary*)remoteEntry;
+ (void)registerLocalModificationForNote:(id <SynchronizedNote>)aNote;

- (NSString*)statusText;
- (NSSet*)activeTasks;
- (void)stop;
- (BOOL)isRunning;
- (NSString*)lastError;

- (BOOL)reachabilityFailed;

- (void)schedulePushForNote:(id <SynchronizedNote>)aNote;

//any DB modifications that will trigger a push must be wrapped in suppress messages to the service
//for added notes, this is done in the callback before actually adding them to allNotes
//for updated notes this is done by the session itself, because it does the updating
//for removed notes this is done right before actually removing them from allNotes (-removeNotes:)
- (void)suppressPushingForNotes:(NSArray*)notes;
- (void)stopSuppressingPushingForNotes:(NSArray*)notes;

- (BOOL)startFetchingListForFullSyncManual;
- (BOOL)startFetchingListForFullSync;

- (void)startCollectingAddedNotesWithEntries:(NSArray*)entries mergingWithNotes:(NSArray*)notesToMerge;
- (void)startCollectingChangedNotesWithEntries:(NSArray*)entries;

- (void)startDeletingNotes:(NSArray*)notes;
- (void)startModifyingNotes:(NSArray*)notes;
- (void)startCreatingNotes:(NSArray*)notes;

- (void)setDelegate:(id)aDelegate;
- (id)delegate;

- (BOOL)pushSyncServiceChanges;
- (BOOL)hasUnsyncedChanges;

@end

@protocol SyncServiceTask

- (NSString*)statusText;
- (SyncResponseFetcher*)currentFetcher;

@end

@interface NSObject (SyncServiceSessionDelegate)

- (void)syncSessionProgressStarted:(id <SyncServiceSession>)syncSession;
- (void)syncSession:(id <SyncServiceSession>)syncSession didStopWithError:(NSString*)errString;

- (void)syncSession:(id <SyncServiceSession>)syncSession receivedFullNoteList:(NSArray*)allEntries;
- (void)syncSession:(id <SyncServiceSession>)syncSession receivedAddedNotes:(NSArray*)addedNotes;
- (void)syncSession:(id <SyncServiceSession>)syncSession didModifyNotes:(NSArray*)changedNotes;
- (void)syncSessionDidFinishRemoteModifications:(id <SyncServiceSession>)syncSession;


@end
