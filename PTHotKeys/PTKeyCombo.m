//
//  PTKeyCombo.m
//  Protein
//
//  Created by Quentin Carnicelli on Sat Aug 02 2003.
//  Copyright (c) 2003 Quentin D. Carnicelli. All rights reserved.
//

#import "PTKeyCombo.h"

#import <Carbon/Carbon.h>

@implementation PTKeyCombo

+ (id)clearKeyCombo
{
	return [self keyComboWithKeyCode: -1 modifiers: -1];
}

+ (id)keyComboWithKeyCode: (int)keyCode modifiers: (int)modifiers
{
	return [[[self alloc] initWithKeyCode: keyCode modifiers: modifiers] autorelease];
}

- (id)initWithKeyCode: (int)keyCode modifiers: (int)modifiers
{
	self = [super init];
	
	if( self )
	{
		mKeyCode = keyCode;
		mModifiers = modifiers;
	}
	
	return self;
}

- (id)initWithPlistRepresentation: (id)plist
{
	int keyCode, modifiers;
		
	keyCode = [[plist objectForKey: @"keyCode"] intValue];
	if( keyCode <= 0 ) keyCode = -1;

	modifiers = [[plist objectForKey: @"modifiers"] intValue];
	if( modifiers <= 0 ) modifiers = -1;

	return [self initWithKeyCode: keyCode modifiers: modifiers];
}

- (id)plistRepresentation
{
	return [NSDictionary dictionaryWithObjectsAndKeys:
				[NSNumber numberWithInt: [self keyCode]], @"keyCode",
				[NSNumber numberWithInt: [self modifiers]], @"modifiers",
				nil];
}

- (id)copyWithZone:(NSZone*)zone;
{
	return [self retain];
}

- (BOOL)isEqual: (PTKeyCombo*)combo
{
	return	[self keyCode] == [combo keyCode] &&
			[self modifiers] == [combo modifiers];
}

#pragma mark -

- (int)keyCode
{
	return mKeyCode;
}

- (int)modifiers
{
	return mModifiers;
}

- (BOOL)isValidHotKeyCombo
{
	return mKeyCode >= 0 && mModifiers > 0;
}

- (BOOL)isClearCombo
{
	return mKeyCode == -1 && mModifiers == -1;
}

@end

#pragma mark -

@implementation PTKeyCombo (UserDisplayAdditions)

+ (NSDictionary*)_keyCodesDictionary
{
	static NSDictionary* keyCodes = nil;
	if( keyCodes == nil ) {
		keyCodes = [[NSDictionary dictionaryWithContentsOfFile:[[NSBundle bundleForClass: self] pathForResource: @"PTKeyCodes" ofType: @"plist"]] retain];
	}
	
	return keyCodes;
}

+ (NSString*)_stringForModifiers: (long)modifiers
{
	static long modToChar[4][2] =
	{
#ifdef __BIG_ENDIAN__
	{ cmdKey, 		0x23180000 },
	{ optionKey,	0x23250000 },
	{ controlKey,	0x005E0000 },
	{ shiftKey,		0x21e70000 }
#else
	{ cmdKey, 		0x00002318 },
	{ optionKey,	0x00002325 },
	{ controlKey,	0x0000005E },
	{ shiftKey,		0x000021e7 }
#endif
	};
	
	NSString* str = nil;
	NSString* charStr;
	long i;
	
	str = [NSString string];

	for( i = 0; i < 4; i++ )
	{
		if( modifiers & modToChar[i][0] )
		{
			charStr = [NSString stringWithCharacters: (const unichar*)&modToChar[i][1] length: 1];
			str = [str stringByAppendingString: charStr];
		}
	}
	
	if( !str )
		str = @"";
	
	return str;
}

+ (NSString*)_stringForKeyCode: (short)keyCode
{
	NSDictionary* dict;
	id key;
	NSString* str;
	
	dict = [self _keyCodesDictionary];
	key = [NSString stringWithFormat: @"%d", keyCode];
	str = [dict objectForKey: key];
	
	if( !str )
		str = [NSString stringWithFormat: @"%X", keyCode];
	
	return str;
}

- (NSString*)description
{
	NSString* desc;
	
	if( [self isValidHotKeyCombo] ) //This might have to change
	{
		desc = [NSString stringWithFormat: @"%@%@",
				[[self class] _stringForModifiers: [self modifiers]],
				[[self class] _stringForKeyCode: [self keyCode]]];
	}
	else
		desc = NSLocalizedString(@"(None)", @"description for no key combination");

	return desc;
}

@end
