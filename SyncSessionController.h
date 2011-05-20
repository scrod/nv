//
//  SyncSessionController.h
//  Notation
//

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
#include <SystemConfiguration/SystemConfiguration.h>
#import <IOKit/IOMessage.h>
#import "SyncServiceSessionProtocol.h"

@class NotationPrefs;

extern NSString *SyncSessionsChangedVisibleStatusNotification;

@interface SyncSessionController : NSObject 
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6
<NSMenuDelegate>
#endif
{

	NSMutableDictionary *syncServiceTimers;
	NSMutableDictionary *syncServiceSessions;
	id syncDelegate;
	NSMenu *statusMenu;
	
	NotationPrefs *notationPrefs;
	
	io_object_t deregisteringNotifier;
	io_connect_t fRootPort;
	IONotificationPortRef notifyPortRef;
	
	NSString *lastUncomittedChangeResultMessage;
	NSMutableSet *uncommittedWaitInvocations;
}

+ (NSArray*)allServiceNames;
+ (NSArray*)allServiceClasses;	

- (void)setSyncDelegate:(id)aDelegate;
- (id)syncDelegate;

- (id)initWithSyncDelegate:(id)aSyncDelegate notationPrefs:(NotationPrefs*)prefs;

- (id<SyncServiceSession>)_sessionForSyncService:(NSString*)serviceName;
- (void)invalidateSyncService:(NSString*)serviceName;
- (void)invalidateAllServices;

- (void)endDelayingSleepWithMessage:(void*)messageArgument;

- (void)disableService:(NSString*)serviceName;
- (void)initializeService:(NSString*)serviceName;
- (void)initializeAllServices;

- (void)schedulePushToAllInitializedSessionsForNote:(id <SynchronizedNote>)aNote;
- (NSArray*)activeSessions;

- (void)_registerPowerChangeCallbackIfNecessary;
- (void)unregisterPowerChangeCallback;

- (void)_updateMenuWithCurrentStatus:(NSMenu*)aMenu;
- (NSMenu*)syncStatusMenu;

- (BOOL)hasRunningSessions;
- (BOOL)hasErrors;
- (void)queueStatusNotification;

- (NSString*)changeCommittingErrorMessage;
- (void)invokeUncommmitedWaitCallbackIfNecessaryReturningError:(NSString*)errString;
- (BOOL)waitForUncommitedChangesWithInvocation:(NSInvocation*)anInvocation;


@end
