//
//  SyncServiceSession.h
//  Notation
//
//  Created by Zachary Schneirov on 12/12/09.
//  Copyright 2009 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "SynchronizedNoteProtocol.h"

@class SyncResponseFetcher;
@class NotationPrefs;

@protocol SyncServiceSession <NSObject>

+ (NSString*)localizedServiceTitle;
+ (NSString*)serviceName;
+ (NSString*)nameOfKeyElement;

- (id)initWithNotationPrefs:(NotationPrefs*)prefs;

- (NSComparisonResult)localEntry:(NSDictionary*)localEntry isNewerThanRemoteEntry:(NSDictionary*)remoteEntry;
- (BOOL)remoteEntryWasMarkedDeleted:(NSDictionary*)remoteEntry;
+ (void)registerModificationForNote:(id <SynchronizedNote>)aNote;

- (void)stop;

- (void)schedulePushForNote:(id <SynchronizedNote>)aNote;

- (void)suppressPushingForNotes:(NSArray*)notes;
- (void)stopSuppressingPushingForNotes:(NSArray*)notes;

- (BOOL)startFetchingListForFullSync;

- (void)startCollectingAddedNotesWithEntries:(NSArray*)entries mergingWithNotes:(NSArray*)someNotes;
- (void)startCollectingChangedNotesWithEntries:(NSArray*)entries;

- (void)startDeletingNotes:(NSArray*)notes;
- (void)startModifyingNotes:(NSArray*)notes;
- (void)startCreatingNotes:(NSArray*)notes;

- (void)setDelegate:(id)aDelegate;
- (id)delegate;

@end

@interface NSObject (SyncServiceSessionDelegate)

//for showing the progress of various operations
//- (void)syncResponseFetcherStarted:(SyncResponseFetcher*)fetcher forService:(id <SyncServiceSession>)syncSession;
//- (void)syncResponseFetcherStopped:(SyncResponseFetcher*)fetcher forService:(id <SyncServiceSession>)syncSession;

- (void)syncSession:(id <SyncServiceSession>)syncSession receivedFullNoteList:(NSArray*)allEntries;
- (void)syncSession:(id <SyncServiceSession>)syncSession receivedAddedNotes:(NSArray*)addedNotes;
- (void)syncSession:(id <SyncServiceSession>)syncSession didModifyNotes:(NSArray*)changedNotes;


- (void)syncSessionDidFinishRemoteModifications:(id <SyncServiceSession>)syncSession;
@end