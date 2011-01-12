//
//  SecureTextEntryManager.h
//  Notation
//
//  Created by Zachary Schneirov on 1/5/11.
//  Copyright 2011 Northwestern University. All rights reserved.
//

#import <Cocoa/Cocoa.h>


extern NSString *ShouldHideSecureTextEntryWarningKey;
extern const char * VerMarker;

@interface SecureTextEntryManager : NSObject {

	BOOL _calledSecureEventInput, secureTextEntry;
}

+ (SecureTextEntryManager*)sharedInstance;

- (void)disableSecureTextEntry;

- (void)enableSecureTextEntry;

- (void)_enableSecureEventInput;
- (void)_disableSecureEventInput;

- (NSSet*)_bundleIdentifiersOfIncompatibleApps;
- (void)checkForIncompatibleApps;

@end
