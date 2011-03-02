//
//  SyncSessionController.h
//  Notation
//

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
