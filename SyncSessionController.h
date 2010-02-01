//
//  SyncSessionController.h
//  Notation
//
//  Created by Zachary Schneirov on 1/23/10.
//  Copyright 2010 Northwestern University. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#include <SystemConfiguration/SystemConfiguration.h>

#import "SyncServiceSessionProtocol.h"

@class NotationPrefs;

extern NSString *SyncSessionsChangedVisibleStatusNotification;

@interface SyncSessionController : NSObject {

	NSMutableDictionary *syncServiceTimers;
	NSMutableDictionary *syncServiceSessions;
	id syncDelegate;
	NSMenu *statusMenu;
	
	NotationPrefs *notationPrefs;
	
	//shouldn't go in the SimplenoteSession class as we probably don't even want an instance hanging around if there's no network:
	//do we have one reachableref for every service? maybe this class should manage a series of SyncServicePref objs instead
	SCNetworkReachabilityRef reachableRef;

	BOOL isConnectedToNetwork;
	BOOL isWaitingForUncommittedChanges;
	id uncommittedWaitTarget;
	SEL uncommittedWaitSelector;
}

+ (NSArray*)allServiceNames;
+ (NSArray*)allServiceClasses;	

- (void)setSyncDelegate:(id)aDelegate;
- (id)syncDelegate;

- (id)initWithSyncDelegate:(id)aSyncDelegate notationPrefs:(NotationPrefs*)prefs;

- (id<SyncServiceSession>)_sessionForSyncService:(NSString*)serviceName;
- (void)invalidateSyncService:(NSString*)serviceName;
- (void)invalidateAllServices;

- (void)disableService:(NSString*)serviceName;
- (void)initializeService:(NSString*)serviceName;
- (void)initializeAllServices;

- (void)schedulePushToAllInitializedSessionsForNote:(id <SynchronizedNote>)aNote;
- (NSArray*)activeSessions;

- (void)invalidateReachabilityRefs;

- (void)_updateMenuWithCurrentStatus:(NSMenu*)aMenu;
- (NSMenu*)syncStatusMenu;

- (BOOL)hasRunningSessions;
- (BOOL)hasErrors;
- (void)queueStatusNotification;

- (void)_invokeUncommittedCallback;
- (void)invokeUncommmitedWaitCallbackIfNecessaryReturningError:(NSString*)errString;
- (BOOL)waitForUncommitedChangesWithTarget:(id)aTarget selector:(SEL)aSEL;


@end
