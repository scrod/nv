//
//  PTHotKeyCenter.h
//  Protein
//
//  Created by Quentin Carnicelli on Sat Aug 02 2003.
//  Copyright (c) 2003 Quentin D. Carnicelli. All rights reserved.
//

#import <AppKit/AppKit.h>

@class PTHotKey;

@interface PTHotKeyCenter : NSObject
{
	NSMutableDictionary*	mHotKeys; //Keys are NSValue of EventHotKeyRef
    NSMutableDictionary*    mHotKeyMap;
    u_int32_t               mNextKeyID;
	BOOL					mEventHandlerInstalled;
}

+ (id)sharedCenter;

//- (void) enterHotKeyWithName:(NSString *)name enable:(BOOL)ena;
- (BOOL)registerHotKey: (PTHotKey*)hotKey;
- (void)unregisterHotKey: (PTHotKey*)hotKey;
- (void) unregisterHotKeyForName:(NSString *)name;
- (void) unregisterAllHotKeys;
- (void) setHotKeyRegistrationForName:(NSString *)name enable:(BOOL)ena;
- (PTHotKey *) hotKeyForName:(NSString *)name;
- (void) updateHotKey:(PTHotKey *)hk;

- (NSArray*)allHotKeys;

@end
