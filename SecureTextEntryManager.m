//
//  SecureTextEntryManager.m
//  Notation
//
//  Created by Zachary Schneirov on 1/5/11.
//  Copyright 2011 Northwestern University. All rights reserved.
//

#import "SecureTextEntryManager.h"
#include <Carbon/Carbon.h>

static SecureTextEntryManager *sharedInstance = nil;

@implementation SecureTextEntryManager

+ (SecureTextEntryManager*)sharedInstance {
	//not synchronized because there should be no need for non-main threads to access this class
	//also, NSThread access potentially enables a locking 
	
	if (sharedInstance == nil)
		sharedInstance = [[SecureTextEntryManager alloc] init];
    return sharedInstance;
}

+ (id)allocWithZone:(NSZone *)zone {
	if (sharedInstance == nil) {
		sharedInstance = [super allocWithZone:zone];
		return sharedInstance;  // assignment and return on first allocation
	}
    return nil; // on subsequent allocation attempts return nil
}

- (id)init {
	if ((self = [super init])) {
		
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) 
													 name:NSApplicationDidBecomeActiveNotification object:NSApp];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) 
													 name:NSApplicationWillResignActiveNotification object:NSApp];		
	}
	return self;
}

- (void)applicationDidBecomeActive:(NSNotification *)aNotification {
	
	if (secureTextEntry) {
		[self _enableSecureEventInput];
	}
}

- (void)applicationWillResignActive:(NSNotification *)aNotification {
	if (secureTextEntry) {
		[self _disableSecureEventInput];
	}
}

//_enableSecureEventInput/_disableSecureEventInput are private; do not call them directly
- (void)_enableSecureEventInput {

	if (!_calledSecureEventInput) {
		NSAssert([NSApp isActive], @"not fair; app is currently inactive");
		//could also assert -[NSThread isMainThread] here
		
		_calledSecureEventInput = YES;
		//NSLog(@"%s: enabled secure input", _cmd);
		
		EnableSecureEventInput();
	}
}

- (void)_disableSecureEventInput {
	if (_calledSecureEventInput) {
		
		DisableSecureEventInput();
		
		//NSLog(@"%s: disabled secure input", _cmd);
		_calledSecureEventInput = NO;
		
		if (IsSecureEventInputEnabled())
			NSLog(@"%s: WARNING: secure input is still enabled, possibly by another app", _cmd);
	}
}


//these enable/disable methods refer to the behavior of calling EnableSecureEventInput/DisableSecureEventInput;
//rather than being wrappers for those calls themselves

- (void)disableSecureTextEntry {
	if (secureTextEntry) {
		[self _disableSecureEventInput];
		
		secureTextEntry = NO;
	}
}

- (void)enableSecureTextEntry {
	
	if (!secureTextEntry) {
		if ([NSApp isActive]) {
			[self _enableSecureEventInput];
		}
		
		secureTextEntry = YES;
	}
}


- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (id)retain {
    return self;
}

- (NSUInteger)retainCount {
    return UINT_MAX;  // denotes an object that cannot be released
}

- (void)release {
    //do nothing
}

- (id)autorelease {
    return self;
}

@end