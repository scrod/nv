//
//  PTKeyComboPanel.m
//  Protein
//
//  Created by Quentin Carnicelli on Sun Aug 03 2003.
//  Copyright (c) 2003 Quentin D. Carnicelli. All rights reserved.
//

#import "PTKeyComboPanel.h"

#import "PTHotKey.h"
#import "PTKeyCombo.h"
#import "PTKeyBroadcaster.h"
#import "PTHotKeyCenter.h"

@implementation PTKeyComboPanel

static id _sharedKeyComboPanel = nil;

+ (id)sharedPanel
{
	if( _sharedKeyComboPanel == nil )
	{
		_sharedKeyComboPanel = [[self alloc] init];
	}

	return _sharedKeyComboPanel;
}

- (id)init
{
    mTitleFormat = @"empty";
    mKeyName = @"empty";
	return [self initWithWindowNibName: @"PTKeyComboPanel"];
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	[mKeyName release];
	[mTitleFormat release];

	[super dealloc];
}

- (void)windowDidLoad
{
	mTitleFormat = [[mTitleField stringValue] retain];

	[[NSNotificationCenter defaultCenter]
		addObserver: self
		selector: @selector( noteKeyBroadcast: )
		name: PTKeyBroadcasterKeyEvent
		object: mKeyBcaster];
}

- (void)_refreshContents
{
    if( mComboField)
		[mComboField setStringValue: [mKeyCombo description]];
    

	if( mTitleField )
		[mTitleField setStringValue: mTitleFormat];
     
}

- (void)chooseHotKeyDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void  *)contextInfo {
	PTHotKey *hotKey = (PTHotKey *)contextInfo;
	
	[[self window] close];
	
	if (hotKey && returnCode == NSOKButton) {
        [hotKey setKeyCombo: [self keyCombo]];
		[[PTHotKeyCenter sharedCenter] updateHotKey: hotKey];
		if ([currentModalDelegate respondsToSelector:@selector(keyComboPanelEnded:)])
			[currentModalDelegate keyComboPanelEnded:self];
		else
			NSLog(@"currentModalDelegate doesn't respond to keyComboPanelEnded:!");
	}
	
	[hotKey release];
	[currentModalDelegate release];
}

- (void)showSheetForHotkey:(PTHotKey*)hotKey forWindow:(NSWindow*)mainWindow modalDelegate:(id)target {
	[[self window] makeFirstResponder:mKeyBcaster];
	
	[self setKeyCombo: [hotKey keyCombo]];
	[self setKeyBindingName: [hotKey name]];
	
	currentModalDelegate = [target retain];
	[hotKey retain];

	[NSApp beginSheet:[self window] modalForWindow:mainWindow modalDelegate:self 
	   didEndSelector:@selector(chooseHotKeyDidEnd:returnCode:contextInfo:) contextInfo:hotKey];
}

- (void)runModalForHotKey: (PTHotKey*)hotKey {
	int resultCode;
    
    [self setKeyCombo: [hotKey keyCombo]];
	[self setKeyBindingName: [hotKey name]];
     
    resultCode = [NSApp runModalForWindow: [self window]];
	[[self window] orderOut:self];
    
	if (resultCode == NSOKButton) {
        [hotKey setKeyCombo: [self keyCombo]];
		[[PTHotKeyCenter sharedCenter] updateHotKey: hotKey];
	}
}

#pragma mark -

- (void)setKeyCombo: (PTKeyCombo*)combo
{
    if (combo == nil)
        combo = [PTKeyCombo clearKeyCombo];
    else
        [combo retain];
    
	[mKeyCombo release];
	mKeyCombo = combo;
	[self _refreshContents];
}

- (PTKeyCombo*)keyCombo
{
	return mKeyCombo;
}

- (void)setKeyBindingName: (NSString*)name
{
	[name retain];
	[mKeyName release];
	mKeyName = name;
	[self _refreshContents];
}

- (NSString*)keyBindingName
{
	return mKeyName;
}

#pragma mark -

- (IBAction)ok: (id)sender {
	if ([[self window] isModalPanel])
		[NSApp stopModalWithCode:NSOKButton];
	else
		[NSApp endSheet:[self window] returnCode:NSOKButton];
		
}

- (IBAction)cancel: (id)sender {
	if ([[self window] isModalPanel])
		[NSApp stopModalWithCode:NSCancelButton];
	else
		[NSApp endSheet:[self window] returnCode:NSCancelButton];
}

- (IBAction)clear: (id)sender
{
    [self setKeyCombo: [PTKeyCombo clearKeyCombo]];
	if ([[self window] isModalPanel])
		[NSApp stopModalWithCode:NSOKButton];
}

- (void)noteKeyBroadcast: (NSNotification*)note
{
	PTKeyCombo* keyCombo = [[note userInfo] objectForKey: @"keyCombo"];

	[self setKeyCombo: keyCombo];
}

@end
