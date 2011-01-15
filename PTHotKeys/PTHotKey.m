//
//  PTHotKey.m
//  Protein
//
//  Created by Quentin Carnicelli on Sat Aug 02 2003.
//  Copyright (c) 2003 Quentin D. Carnicelli. All rights reserved.
//

#import "PTHotKey.h"

#import "PTHotKeyCenter.h"
#import "PTKeyCombo.h"

@implementation PTHotKey

- (id)init
{
	self = [super init];
	
	if( self )
	{
		[self setKeyCombo: [PTKeyCombo clearKeyCombo]];
	}
	
	return self;
}

- (void)dealloc
{
	[mName release];
	[mKeyCombo release];
	
	[super dealloc];
}

- (NSString*)description
{
	return [NSString stringWithFormat: @"<%@: %@>", NSStringFromClass( [self class] ), [self keyCombo]];
}

#pragma mark -

- (EventHotKeyRef)carbonHotKey {
	return carbonHotKey;
}

- (void)setCarbonHotKey:(EventHotKeyRef)hotKey {
	carbonHotKey = hotKey;
}

- (void)setKeyCombo: (PTKeyCombo*)combo
{
	[combo retain];
	[mKeyCombo release];
	mKeyCombo = combo;
}

- (PTKeyCombo*)keyCombo
{
	return mKeyCombo;
}

- (void)setName: (NSString*)name
{
	[name retain];
	[mName release];
	mName = name;
}

- (NSString*)name
{
	return mName;
}

- (void)setTarget: (id)target
{
	mTarget = target;
}

- (id)target
{
	return mTarget;
}

- (void)setAction: (SEL)action
{
	mAction = action;
}

- (SEL)action
{
	return mAction;
}

- (void)invoke
{
	[mTarget performSelector: mAction withObject: self];
}

@end
