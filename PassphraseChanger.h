/* PassphraseChanger */

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import <Cocoa/Cocoa.h>

@class NotationPrefs;
@class KeyDerivationManager;

@interface PassphraseChanger : NSObject
{
    IBOutlet NSButton *cancelChangedButton;
    IBOutlet NSPanel *changePassphraseWindow;
    IBOutlet NSSecureTextField *currentPasswordField;
    IBOutlet NSSecureTextField *newPasswordField;
    IBOutlet NSButton *okChangeButton;
    IBOutlet NSButton *rememberChangeButton;
    IBOutlet NSSecureTextField *verifyChangedPasswordField;
	IBOutlet NSButton *disclosureButton;
	IBOutlet NSTextField *advancedHelpField;
	IBOutlet NSView *dismissalButtonsView, *upperButtonsView, *advancedView;
	
	KeyDerivationManager *keyDerivation;	
	NotationPrefs *notationPrefs;
}

- (IBAction)cancelNewPassword:(id)sender;
- (IBAction)okNewPassword:(id)sender;
- (IBAction)discloseAdvancedSettings:(id)sender;
- (void)showAroundWindow:(NSWindow*)window;
- (id)initWithNotationPrefs:(NotationPrefs*)prefs;

@end
