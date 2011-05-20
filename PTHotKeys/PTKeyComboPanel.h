//
//  PTKeyComboPanel.h
//  Protein
//
//  Created by Quentin Carnicelli on Sun Aug 03 2003.
//  Copyright (c) 2003 Quentin D. Carnicelli. All rights reserved.
//

#import <AppKit/AppKit.h>

@class PTKeyBroadcaster;
@class PTKeyCombo;
@class PTHotKey;

@interface PTKeyComboPanel : NSWindowController
{
	IBOutlet NSTextField*		mTitleField;
	IBOutlet NSTextField*		mComboField;
	IBOutlet PTKeyBroadcaster*	mKeyBcaster;
	
	id currentModalDelegate;

	NSString*				mTitleFormat;
	NSString*				mKeyName;
	PTKeyCombo*				mKeyCombo;
}

+ (id)sharedPanel;

- (void)showSheetForHotkey:(PTHotKey*)hotKey forWindow:(NSWindow*)mainWindow modalDelegate:(id)target;

- (void)runModalForHotKey: (PTHotKey*)hotKey;

- (void)setKeyCombo: (PTKeyCombo*)combo;
- (PTKeyCombo*)keyCombo;

- (void)setKeyBindingName: (NSString*)name;
- (NSString*)keyBindingName;

- (IBAction)ok: (id)sender;
- (IBAction)cancel: (id)sender;
- (IBAction)clear: (id)sender;
@end


@interface PTKeyComboPanel (ModalDelegate)
- (void)keyComboPanelEnded:(PTKeyComboPanel*)panel;
@end
