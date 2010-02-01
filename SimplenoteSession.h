//
//  SimplenoteSession.h
//  Notation
//
//  Created by Zachary Schneirov on 12/4/09.
//  Copyright 2009 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "SyncResponseFetcher.h"
#import "SyncServiceSessionProtocol.h"
#include <SystemConfiguration/SystemConfiguration.h>

@class NoteObject;
@class DeletedNoteObject;
@class NotationPrefs;
@class SimplenoteEntryCollector;

extern NSString *SimplenoteServiceName;
extern NSString *SimplenoteSeparatorKey;

@interface SimplenoteSession : NSObject <SyncServiceSession, NSCopying> {

	NSString *emailAddress, *password, *authToken;
	
	NSDate *lastSyncedTime;
	BOOL lastIndexAuthFailed;
	NSString *lastErrorString;
	
	SyncResponseFetcher *loginFetcher, *listFetcher;
	
	//used for scheduling mutations:
	//e.g., controlling whether a given note should be scheduled
	NSTimer *pushTimer;
	NSCountedSet *notesToSuppressPushing;
	NSMutableSet *unsyncedServiceNotes;
	
	//used for per-note queuing of mutations:
	//e.g., ensuring that multiple modifications affecting the same note do not occur simultaneously
	//modifications to notes contained in notesBeingModified should be added to queuedNoteInvocations
	NSMutableSet *notesBeingModified;
	NSMutableDictionary *queuedNoteInvocations;
	
	NSMutableSet *collectorsInProgress;
	
	id delegate;
}

- (id)initWithNotationPrefs:(NotationPrefs*)prefs;

+ (NSString*)localizedServiceTitle;
+ (NSString*)serviceName;
+ (NSString*)nameOfKeyElement;
+ (NSURL*)servletURLWithPath:(NSString*)path parameters:(NSDictionary*)params;
+ (SCNetworkReachabilityRef)createReachabilityRefWithCallback:(SCNetworkReachabilityCallBack)callout target:(id)aTarget;

- (NSComparisonResult)localEntry:(NSDictionary*)localEntry compareToRemoteEntry:(NSDictionary*)remoteEntry;
- (BOOL)remoteEntryWasMarkedDeleted:(NSDictionary*)remoteEntry;
- (BOOL)entryHasLocalChanges:(NSDictionary*)entry;

+ (void)registerLocalModificationForNote:(id <SynchronizedNote>)aNote;

- (void)schedulePushForNote:(id <SynchronizedNote>)aNote;
- (void)handleSyncServiceChanges:(NSTimer*)aTimer;
- (BOOL)pushSyncServiceChanges;

- (void)stop;
- (NSSet*)activeTasks;

- (NSString*)lastError;
- (void)clearErrors;
- (BOOL)isRunning;

- (BOOL)hasUnsyncedChanges;

- (id)initWithUsername:(NSString*)aUserString andPassword:(NSString*)aPassString;

- (void)setDelegate:(id)aDelegate;
- (id)delegate;

- (SyncResponseFetcher*)loginFetcher;
- (SyncResponseFetcher*)listFetcher;

- (void)_stoppedWithErrorString:(NSString*)aString;
- (void)_updateSyncTime;
- (void)_clearAuthTokenAndDependencies;
- (BOOL)_checkToken;

- (NSArray*)_notesWithEntries:(NSArray*)entries;
- (NSMutableDictionary*)_invertedContentHashesOfNotes:(NSArray*)notes withSeparator:(NSString*)sep;

- (void)_registerCollector:(SimplenoteEntryCollector*)collector;
- (void)_unregisterCollector:(SimplenoteEntryCollector*)collector;

- (void)_queueInvocation:(NSInvocation*)anInvocation forNote:(id<SynchronizedNote>)aNote;
- (NSInvocation*)_popNextInvocationForNote:(id<SynchronizedNote>)aNote;;

- (void)_modifyNotes:(NSArray*)notes withOperation:(SEL)opSEL;

- (void)startCollectingAddedNotesWithEntries:(NSArray*)entries mergingWithNotes:(NSArray*)notesToMerge;
- (void)startCollectingChangedNotesWithEntries:(NSArray*)entries;

- (BOOL)startFetchingListForFullSyncManual;
- (BOOL)startFetchingListForFullSync;

@end
