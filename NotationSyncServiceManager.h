//
//  NotationSyncServiceManager.h
//  Notation
//
//  Created by Zachary Schneirov on 11/29/09.
//  Copyright 2009 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "NotationController.h"
#import "SyncServiceSessionProtocol.h"

@interface NotationController (NotationSyncServiceManager)

- (NSDictionary*)invertedDictionaryOfEntries:(NSArray*)entries keyedBy:(NSString*)keyName;
- (NSDictionary*)invertedDictionaryOfNotes:(NSArray*)someNotes forSession:(id<SyncServiceSession>)aSession;

- (void)makeNotesMatchList:(NSArray*)MDEntries fromSyncSession:(id <SyncServiceSession>)syncSession;

- (void)schedulePushToAllSyncServicesForNote:(id <SynchronizedNote>)aNote;

- (void)startSyncServices;
- (void)stopSyncServices;

- (BOOL)handleSyncingWithAllMissingAndRemoteNoteCount:(NSUInteger)foundNotes fromSession:(id <SyncServiceSession>)aSession;

@end
