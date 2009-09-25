//
//  PTHotKey.h
//  Protein
//
//  Created by Quentin Carnicelli on Sat Aug 02 2003.
//  Copyright (c) 2003 Quentin D. Carnicelli. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import "PTKeyCombo.h"

@interface PTHotKey : NSObject {
	NSString*		mName;
	PTKeyCombo*		mKeyCombo;
	id				mTarget;
	SEL				mAction;
	EventHotKeyRef  carbonHotKey;
}

- (id)init;

- (void)setName: (NSString*)name;
- (NSString*)name;

- (EventHotKeyRef)carbonHotKey;
- (void)setCarbonHotKey:(EventHotKeyRef)hotKey;

- (void)setKeyCombo: (PTKeyCombo*)combo;
- (PTKeyCombo*)keyCombo;

- (void)setTarget: (id)target;
- (id)target;
- (void)setAction: (SEL)action;
- (SEL)action;

- (void)invoke;

@end
