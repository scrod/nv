//
//  PTHotKeyCenter.m
//  Protein
//
//  Created by Quentin Carnicelli on Sat Aug 02 2003.
//  Copyright (c) 2003 Quentin D. Carnicelli. All rights reserved.
//

#import "PTHotKeyCenter.h"
#import "PTHotKey.h"
#import "PTKeyCombo.h"
#import <Carbon/Carbon.h>

@interface PTHotKeyCenter (Private)
- (void)_updateEventHandler;
- (void)_hotKeyDown: (PTHotKey*)hotKey;
- (void)_hotKeyUp: (PTHotKey*)hotKey;
static OSStatus hotKeyEventHandler(EventHandlerCallRef inHandlerRef, EventRef inEvent, void* refCon );
@end

@implementation PTHotKeyCenter

static id _sharedHotKeyCenter = nil;

+ (id)sharedCenter
{
	if( _sharedHotKeyCenter == nil )
	{
		_sharedHotKeyCenter = [[self alloc] init];
	}
	
	return _sharedHotKeyCenter;
}

- (id)init
{
	self = [super init];
	
	if( self )
	{
		mHotKeys = [[NSMutableDictionary alloc] init];
        mHotKeyMap = [[NSMutableDictionary alloc] init];
        mNextKeyID = 1;
	}
	
	return self;
}

- (void)dealloc
{
	[mHotKeys release];
	[super dealloc];
}

#pragma mark -

- (BOOL)registerHotKey: (PTHotKey*)hotKey
{
    //NSLog(@"registerHotKey: %@", hotKey);
	OSStatus err;
	EventHotKeyID hotKeyID;
	EventHotKeyRef carbonHotKey;
/*
	if([mHotKeys objectForKey:[hotKey name]])
    	[self unregisterHotKey: hotKey];
*/	
	if( [[hotKey keyCombo] isValidHotKeyCombo] == NO )
    {
        //NSLog(@"not valid keycombo:");
        return YES;
    }
		
	
	hotKeyID.signature = UTGetOSTypeFromString(CFSTR("PTHk"));
	hotKeyID.id = mNextKeyID;
    
	//NSLog(@"registering...");
	err = RegisterEventHotKey(  [[hotKey keyCombo] keyCode],
								[[hotKey keyCombo] modifiers],
								hotKeyID,
								GetEventDispatcherTarget(),
								0,
								&carbonHotKey );

	if( err )
    {
        //NSLog(@"error --");
        return NO;
    }
	
    NSNumber *kid = [NSNumber numberWithUnsignedInt:mNextKeyID];
    [mHotKeyMap setObject:hotKey forKey:kid];
    mNextKeyID += 1;
    

    [hotKey setCarbonHotKey:carbonHotKey];
	[mHotKeys setObject: hotKey forKey: [hotKey name]];

	[self _updateEventHandler];
	//NSLog(@"Eo registerHotKey:");
	return YES;
}

- (void)unregisterHotKey: (PTHotKey*)hotKey
{
    //NSLog(@"unregisterHotKey: %@", hotKey);
	EventHotKeyRef carbonHotKey;

	if(![mHotKeys objectForKey:[hotKey name]])
		return;
	
	carbonHotKey = [hotKey carbonHotKey];
	NSAssert( carbonHotKey != nil, @"" );

	(void)UnregisterEventHotKey( carbonHotKey );
	//Watch as we ignore 'err':

	[mHotKeys removeObjectForKey: [hotKey name]];
    NSArray *remKeys = [mHotKeyMap allKeysForObject:hotKey];
    if (remKeys && [remKeys count] > 0)
        [mHotKeyMap removeObjectsForKeys:remKeys];
	
	[self _updateEventHandler];
    //NSLog(@"Eo unregisterHotKey:");
	//See that? Completely ignored
}

- (void) unregisterHotKeyForName:(NSString *)name
{
    [self unregisterHotKey:[mHotKeys objectForKey:name]];
}

- (void) unregisterAllHotKeys;
{
    NSEnumerator *enumerator = [mHotKeys objectEnumerator];
    id thing;
    while ((thing = [enumerator nextObject]))
    {
        [self unregisterHotKey:thing];
    }
}

- (void) setHotKeyRegistrationForName:(NSString *)name enable:(BOOL)ena
{
    if (ena)
    {
        [self registerHotKey:[mHotKeys objectForKey:name]];
    } else
    {
        [self unregisterHotKey:[mHotKeys objectForKey:name]];
    }
}

- (void) updateHotKey:(PTHotKey *)hk
{
    [hk retain];
    //NSLog(@"updateHotKey: %@", hk);
    [self unregisterHotKey:[mHotKeys objectForKey:[hk name]]];
    //NSLog(@"unreg'd: %@", hk);
    [self registerHotKey:hk];
    //NSLog(@"Eo updateHotKey:");
}

- (PTHotKey *) hotKeyForName:(NSString *)name
{
    return [mHotKeys objectForKey:name];
}

- (NSArray*)allHotKeys
{
	return [mHotKeys allValues];
}

#pragma mark -
- (void)_updateEventHandler
{
	if( [mHotKeys count] && mEventHandlerInstalled == NO )
	{
		EventTypeSpec eventSpec[2] = {
			{ kEventClassKeyboard, kEventHotKeyPressed },
			{ kEventClassKeyboard, kEventHotKeyReleased }
		};    

		InstallEventHandler( GetEventDispatcherTarget(),
							 (EventHandlerProcPtr)hotKeyEventHandler, 
							 2, eventSpec, nil, nil);
	
		mEventHandlerInstalled = YES;
	}
}

- (void)_hotKeyDown: (PTHotKey*)hotKey
{
	[hotKey invoke];
}

- (void)_hotKeyUp: (PTHotKey*)hotKey
{
    //[hotKey uninvoke];
}

- (OSStatus)sendCarbonEvent: (EventRef)event
{
	OSStatus err;
	EventHotKeyID hotKeyID;
	PTHotKey* hotKey;

	NSAssert( GetEventClass( event ) == kEventClassKeyboard, @"Unknown event class" );

	err = GetEventParameter(	event,
								kEventParamDirectObject, 
								typeEventHotKeyID,
								nil,
								sizeof(EventHotKeyID),
								nil,
								&hotKeyID );
	if( err )
		return err;
	

	NSAssert( hotKeyID.signature == UTGetOSTypeFromString(CFSTR("PTHk")), @"Invalid hot key id" );

    NSNumber *kid = [NSNumber numberWithUnsignedInt:hotKeyID.id];
	hotKey = [mHotKeyMap objectForKey:kid];
    
    NSAssert( hotKey != nil, @"Invalid hot key id" );

	switch( GetEventKind( event ) )
	{
		case kEventHotKeyPressed:
            [self _hotKeyDown: hotKey];
            break;

		case kEventHotKeyReleased:
            [self _hotKeyUp: hotKey];
            break;

		default:
			NSAssert( 0, @"Unknown event kind" );
	}
	
	return noErr;
}

static OSStatus hotKeyEventHandler(EventHandlerCallRef inHandlerRef, EventRef inEvent, void* refCon )
{
	return [[PTHotKeyCenter sharedCenter] sendCarbonEvent: inEvent];
}

@end
