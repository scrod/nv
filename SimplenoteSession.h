//
//  SimplenoteSession.h
//  Notation
//
//  Created by Zachary Schneirov on 12/4/09.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
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
	
	CFAbsoluteTime lastSyncedTime;
	BOOL lastIndexAuthFailed, reachabilityFailed;
	NSString *lastErrorString;
	
	SCNetworkReachabilityRef reachableRef;
	
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
	
	//used to span multiple partial index fetches (when mark is present in response)
	NSMutableArray *indexEntryBuffer;
	NSString *indexMark;
	
	id delegate;
}

- (id)initWithNotationPrefs:(NotationPrefs*)prefs;

+ (NSString*)localizedServiceTitle;
+ (NSString*)serviceName;
+ (NSString*)nameOfKeyElement;
+ (NSURL*)servletURLWithPath:(NSString*)path parameters:(NSDictionary*)params;
+ (SCNetworkReachabilityRef)createReachabilityRefWithCallback:(SCNetworkReachabilityCallBack)callout target:(id)aTarget;
//+ (NSString*)localizedNetworkDiagnosticMessage;
- (void)invalidateReachabilityRefs;
- (BOOL)reachabilityFailed;

- (NSComparisonResult)localEntry:(NSDictionary*)localEntry compareToRemoteEntry:(NSDictionary*)remoteEntry;
-(void)applyMetadataUpdatesToNote:(id <SynchronizedNote>)aNote localEntry:(NSDictionary *)localEntry remoteEntry: (NSDictionary *)remoteEntry;
- (BOOL)remoteEntryWasMarkedDeleted:(NSDictionary*)remoteEntry;
- (BOOL)entryHasLocalChanges:(NSDictionary*)entry;
- (BOOL)tagsShouldBeMergedForEntry:(NSDictionary*)entry;

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
