//
//  SecureTextEntryManager.h
//  Notation
//
//  Created by Zachary Schneirov on 1/5/11.
//  Copyright 2011 Northwestern University. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface SecureTextEntryManager : NSObject {

	BOOL _calledSecureEventInput, secureTextEntry;
}

+ (SecureTextEntryManager*)sharedInstance;

- (void)disableSecureTextEntry;

- (void)enableSecureTextEntry;

- (void)_enableSecureEventInput;
- (void)_disableSecureEventInput;

@end
