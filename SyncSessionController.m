//
//  SyncSessionController.m
//  Notation
//
//  Created by Zachary Schneirov on 1/23/10.
//  Copyright 2010 Northwestern University. All rights reserved.
//

#import "SyncSessionController.h"
#import "NotationPrefs.h"
#import "SyncServiceSessionProtocol.h"
#import "SimplenoteSession.h"

NSString *SyncSessionsChangedVisibleStatusNotification = @"SSCVSN";

@implementation SyncSessionController

static void SNReachabilityCallback(SCNetworkReachabilityRef	target, SCNetworkConnectionFlags flags, void * info);

- (id)initWithSyncDelegate:(id)aSyncDelegate notationPrefs:(NotationPrefs*)prefs {
	if ([super init]) {
		if (!(syncDelegate = aSyncDelegate)) {
			NSLog(@"%s: need syncDelegate!", _cmd);
			return nil;
		}
		if (!(notationPrefs = [prefs retain])) {
			NSLog(@"%s: need notationPrefs!", _cmd);
			return nil;
		}
		syncServiceTimers = [[NSMutableDictionary alloc] init];
		//assume true until we try to create a sync service and discover otherwise
		isConnectedToNetwork = YES;
	}
	return self;
}

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

- (void)setSyncDelegate:(id)aDelegate {
	syncDelegate = aDelegate;
}
- (id)syncDelegate {
	return syncDelegate;
}

static void SNReachabilityCallback(SCNetworkReachabilityRef	target, SCNetworkConnectionFlags flags, void * info) {
    
	SyncSessionController *self = (SyncSessionController *)info;
	BOOL reachable = ((flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired));
	self->isConnectedToNetwork = reachable;
	
	if (reachable) {
		//for each service, try to initialize it _unless_ it already exists
		NSArray *svcs = [[self class] allServiceNames];
		NSUInteger i = 0;
		for (i=0; i<[svcs count]; i++) {
			NSString *serviceName = [svcs objectAtIndex:i];
			if (![self->syncServiceSessions objectForKey:serviceName]) [self initializeService:serviceName];
		}
	} else {
		//shut everything down so they don't repeatedly complain
		[self invalidateAllServices];
	}
	[self queueStatusNotification];
	[[NSNotificationCenter defaultCenter] postNotificationName:SyncPrefsDidChangeNotification object:nil];
}


- (id<SyncServiceSession>)_sessionForSyncService:(NSString*)serviceName {
	//map names to sync service sessions, creating them if necessary
	NSAssert(serviceName != nil, @"servicename is required");
	
	if (!syncServiceSessions) syncServiceSessions = [[NSMutableDictionary alloc] initWithCapacity:1];
	
	id<SyncServiceSession> session = [syncServiceSessions objectForKey:serviceName];
	
	if (!session) {
		//don't allow services to be created when we KNOW we're not connected
		if (!isConnectedToNetwork) return nil;
		
		if ([serviceName isEqualToString:SimplenoteServiceName]) {
			
			if (![notationPrefs syncServiceIsEnabled:SimplenoteServiceName]) return nil;
			
			SimplenoteSession *snSession = [[SimplenoteSession alloc] initWithNotationPrefs:notationPrefs];
			if (snSession) {
				[syncServiceSessions setObject:snSession forKey:serviceName];
				[snSession setDelegate:syncDelegate];
				[snSession release]; //owned by syncServiceSessions
				
				//if we could at least init the session, create a reachability ref to take it up or down
				if (!reachableRef) reachableRef = [SimplenoteSession createReachabilityRefWithCallback:SNReachabilityCallback target:self];
			}
			return snSession;
		} /* else if ([serviceName isEqualToString:SimpletextServiceName]) {
		   
		   //init and return other services here
		   
		   } */ else {
			   NSLog(@"%s: unknown service named '%@'", _cmd, serviceName);
		   }
	}
	return session;
}

- (void)invalidateSyncService:(NSString*)serviceName {
	id<SyncServiceSession> session = [[[syncServiceSessions objectForKey:serviceName] retain] autorelease];
	[session stop];
	[session setDelegate:nil];
	[syncServiceSessions removeObjectForKey:serviceName];
	
	[[syncServiceTimers objectForKey:serviceName] invalidate];
	[syncServiceTimers removeObjectForKey:serviceName];
}

- (void)initializeService:(NSString*)serviceName {
	[self queueStatusNotification];
	
	id <SyncServiceSession> session = [[[self _sessionForSyncService:serviceName] retain] autorelease];
	if (session) {
		if (![syncServiceTimers objectForKey:serviceName]) {
			
			NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:[notationPrefs syncFrequencyInMinutesForServiceName:serviceName] * 60.0
															  target:self selector:@selector(handleSyncServiceTimer:) userInfo:session repeats:YES];
			[syncServiceTimers setObject:timer forKey:serviceName];
		}
		
		//start syncing now
		[session startFetchingListForFullSync];
	}
}

- (void)handleSyncServiceTimer:(NSTimer*)aTimer {
	id <SyncServiceSession> session = [aTimer userInfo];
	NSAssert([session conformsToProtocol:@protocol(SyncServiceSession)], @"incorrect userinfo object from sync timer");
	
	//file notifications are not always caught without user activity; let's make sure the directory is always in sync
	//this will have the side effect of showing the deletion-warning sheet at potentially unexpected times
	if ([syncDelegate respondsToSelector:@selector(synchronizeNotesFromDirectory)])
		[syncDelegate synchronizeNotesFromDirectory];
	
	[session startFetchingListForFullSync];
}

- (void)disableService:(NSString*)serviceName {
	//stops the service, turns it off, and removes the password
	[self invalidateSyncService:serviceName];
	[notationPrefs setSyncEnabled:NO forService:serviceName];
	[notationPrefs removeSyncPasswordForService:serviceName];
	//remove password to prevent instant reactivation of whatever alert ultimately prompted this action, if the user re-enables the service
	//should not need this; this class should control sync prefs directly, or at least syncprefs objs
	[[NSNotificationCenter defaultCenter] postNotificationName:SyncPrefsDidChangeNotification object:nil];
}

- (void)invalidateAllServices {
	NSArray *svcs = [[[syncServiceSessions allKeys] copy] autorelease];
	NSUInteger i = 0;
	for (i=0; i<[svcs count]; i++) [self invalidateSyncService:[svcs objectAtIndex:i]];
}

- (void)initializeAllServices {
	NSArray *svcs = [[self class] allServiceNames];
	NSUInteger i = 0;
	for (i=0; i<[svcs count]; i++) [self initializeService:[svcs objectAtIndex:i]];
}


- (void)schedulePushToAllInitializedSessionsForNote:(id <SynchronizedNote>)aNote {
	[[syncServiceSessions allValues] makeObjectsPerformSelector:@selector(schedulePushForNote:) withObject:aNote];
}

- (NSArray*)activeSessions {
	return [syncServiceSessions allValues];
}

- (void)invalidateReachabilityRefs {
	
	if (reachableRef) {
		SCNetworkReachabilityUnscheduleFromRunLoop(reachableRef, CFRunLoopGetCurrent(),kCFRunLoopDefaultMode); 
		CFRelease(reachableRef);
		reachableRef = nil;
	}
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
	[self _updateMenuWithCurrentStatus:menu];
}

- (void)_updateMenuWithCurrentStatus:(NSMenu*)aMenu {
	
	if (IsSnowLeopardOrLater) {
		[aMenu performSelector:@selector(removeAllItems)];
	} else {
		while ([aMenu numberOfItems])
			[aMenu removeItemAtIndex:0];
	}
	//BUG: on Tiger this creates an extra item that appears at the _bottom_ of the pulldown,
	//but on Leopard and above the first item is rightly used as the "title" of the button
	[aMenu addItem:[NSMenuItem separatorItem]];
	
	//for each service that NV can handle, add a section to the menu with information about its current session, if one exists
	NSArray *svcs = [[self class] allServiceNames];
	NSUInteger i = 0;
	for (i=0; i<[svcs count]; i++) {
		Class class = [[[self class] allServiceClasses] objectAtIndex:i];
		NSString *serviceName = [svcs objectAtIndex:i];
		BOOL isEnabled = [notationPrefs syncServiceIsEnabled:serviceName];
		
		//"<Name>" (if disabled, "<Name>: Disabled")
		NSMenuItem *serviceHeaderItem = [[[NSMenuItem alloc] initWithTitle: isEnabled ? [class localizedServiceTitle] : 
										  [NSString stringWithFormat:NSLocalizedString(@"%@: Disabled", @"<Sync Service Name>: Disabled"), [class localizedServiceTitle]]
																	action:nil keyEquivalent:@""] autorelease];
		[serviceHeaderItem setEnabled:NO];
		[aMenu addItem:serviceHeaderItem];
		
		id <SyncServiceSession> session = [syncServiceSessions objectForKey:serviceName];
		if (session) {
			NSArray *tasks = [[session activeTasks] allObjects];
			if ([tasks count]) {
				//one item per task
				NSUInteger j = 0;
				for (j=0; j<[tasks count]; j++) {
					NSMenuItem *taskItem = [[[NSMenuItem alloc] initWithTitle:[[tasks objectAtIndex:j] statusText] action:NULL keyEquivalent:@""] autorelease];
					[taskItem setEnabled:NO];
					[aMenu addItem:taskItem];
				}
			} else {
				//use the session-level status
				NSMenuItem *sessionStatusItem = [[[NSMenuItem alloc] initWithTitle:[session statusText] action:NULL keyEquivalent:@""] autorelease];
				[sessionStatusItem setEnabled:NO];
				[aMenu addItem:sessionStatusItem];
			}
			
			//now for the ACTION items:
			[aMenu addItem:[NSMenuItem separatorItem]];
			
			//if running "stop"; otherwise, "sync":
			if ([session isRunning]) {
				NSMenuItem *stopItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Stop Synchronizing", nil) action:@selector(stop) keyEquivalent:@""] autorelease];
				[stopItem setEnabled:YES];
				[stopItem setTarget:session];
				[aMenu addItem:stopItem];
			} else {
				NSMenuItem *syncItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Synchronize Now", nil) 
																   action:@selector(startFetchingListForFullSyncManual) keyEquivalent:@""] autorelease];
				[syncItem setEnabled:YES];
				[syncItem setTarget:session];
				[aMenu addItem:syncItem];				
			}
			
			
		} else {
			//can't provide any information other than enabled/disabled
			//if enabled, a message that the user or password is missing
			//if neither is missing, a generic error that ought never appear
			NSDictionary *acctDict = [notationPrefs syncAccountForServiceName:serviceName];
			NSMenuItem *badItem = nil;
			if (![acctDict objectForKey:@"username"] || ![acctDict objectForKey:@"password"]) {
				badItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Incorrect login and password", @"sync status menu msg")
													  action:nil keyEquivalent:@""] autorelease];
			} else if (isEnabled) {
				
				NSString *title = isConnectedToNetwork ? NSLocalizedString(@"Session could not be created", nil) : 
				NSLocalizedString(@"Internet unavailable.", @"message to report when sync service is not reachable over internet");
				badItem = [[[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""] autorelease];
			}
			[badItem setEnabled:NO];
			if (badItem) [aMenu addItem:badItem];
		}
		if (i < [svcs count] - 1) {
			[aMenu addItem:[NSMenuItem separatorItem]];
		}
		
	}
}

- (NSMenu*)syncStatusMenu {
	if (!statusMenu) {
		statusMenu = [[NSMenu alloc] initWithTitle:@"Sync Status"];
		[statusMenu setAutoenablesItems:NO];
		[statusMenu setDelegate:self];
	}
	return statusMenu;
}

- (BOOL)hasRunningSessions {
	NSArray *sessions = [syncServiceSessions allValues];
	NSUInteger i = 0;
	for (i=0; i<[sessions count]; i++) {
		if ([[sessions objectAtIndex:i] isRunning]) return YES;
	}
	return NO;
}

- (BOOL)hasErrors {
	NSArray *svcs = [[self class] allServiceNames];
	NSUInteger i = 0;
	for (i=0; i<[svcs count]; i++) {
		NSString *serviceName = [svcs objectAtIndex:i];
		if ([notationPrefs syncServiceIsEnabled:serviceName]) {
			//only report errors for those services with which the user is expecting (or hoping) to sync
			id <SyncServiceSession> session = [syncServiceSessions objectForKey:serviceName];
			if (!session) return YES;
			if (![session isRunning]) {
				//report errors for only stopped sessions
				if ([session lastError]) return YES;
			}
		}
	}
	return NO;
}

- (void)queueStatusNotification {
	//send an alert telling people to check our -hasErrors and -hasRunningSessions methods
	NSNotification *aNote = [NSNotification notificationWithName:SyncSessionsChangedVisibleStatusNotification object:self];
	[[NSNotificationQueue defaultQueue] enqueueNotification:aNote postingStyle:NSPostWhenIdle coalesceMask:NSNotificationCoalescingOnName forModes:nil];
}

- (void)_invokeUncommittedCallback {
	isWaitingForUncommittedChanges = NO;
	[uncommittedWaitTarget performSelector:uncommittedWaitSelector];	
}

- (void)invokeUncommmitedWaitCallbackIfNecessaryReturningError:(NSString*)errString {
	if (isWaitingForUncommittedChanges) {
		if ([errString length]) {
			//fail on the first occur that occurs; currently doesn't provide an opportunity for continuing to sync with other non-failed svcs
			NSRunAlertPanel(NSLocalizedString(@"Changes could not be uploaded.", nil), errString, @"Quit", nil, nil);
			[self _invokeUncommittedCallback];
		} else if (![self hasRunningSessions]) {
			[self _invokeUncommittedCallback];
		}
	}
}

- (BOOL)waitForUncommitedChangesWithTarget:(id)aTarget selector:(SEL)aSEL {
	// push any uncommitted notes for all sessions, so that those will then be running
	// if we didn't have to push for any of the sessions AND none of the sessions are running, then return right away; there are no changes left to send
	
	// syncDelegate invokes selector on target when any currently running sessions have stopped and no sessions have any more uncommited notes
	// it must call invokeUncommmitedWaitCallbackIfNecessary from -syncSession:didStopWithError:
	
	if (isWaitingForUncommittedChanges) return YES; //we're already waiting
	
	NSAssert([aTarget respondsToSelector:aSEL], @"target doesn't respond to callback");
	uncommittedWaitTarget = aTarget;
	uncommittedWaitSelector = aSEL;
	
	BOOL willNeedToWait = NO;
	NSArray *sessions = [syncServiceSessions allValues];
	NSUInteger i = 0;
	for (i=0; i<[sessions count]; i++) {
		id <SyncServiceSession> session = [sessions objectAtIndex:i];
		if ([session hasUnsyncedChanges]) {
			if (!(![session pushSyncServiceChanges] && ![session isRunning])) {
				willNeedToWait = YES;
				isWaitingForUncommittedChanges = YES;
			}
		}
	}
	
	return willNeedToWait;
}


- (void)dealloc {
	
	if (reachableRef) CFRelease(reachableRef);
	
	[statusMenu release];
	[syncServiceTimers release];
	[syncServiceSessions release];
	[notationPrefs release];
	
	[super dealloc];
}

@end
