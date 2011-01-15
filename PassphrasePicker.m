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


#import "PassphrasePicker.h"
#import "NotationPrefs.h"
#import "KeyDerivationManager.h"
#import <Carbon/Carbon.h>

@implementation PassphrasePicker


- (id)initWithNotationPrefs:(NotationPrefs*)prefs {
	
	if ([super init]) {
		notationPrefs = [prefs retain];
		
		
	}
	return self;
}
- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[notationPrefs release];
	[keyDerivation release];
	[super dealloc];
}

- (void)awakeFromNib {
	
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(textDidChange:)
				   name:NSControlTextDidChangeNotification object:newPasswordField];
	[center addObserver:self selector:@selector(textDidChange:)
				   name:NSControlTextDidChangeNotification object:verifyNewPasswordField];
	
}

- (IBAction)discloseAdvancedSettings:(id)sender {
	BOOL disclosed = [disclosureButton state];
	int heightDifference = disclosed ? 118 : -118;
	
	if (disclosed) {
		[self performSelector:@selector(setAdvancedViewHidden:) 
				   withObject:[NSNumber numberWithBool:NO] afterDelay:0.0];
	} else {
		[advancedView setHidden:YES];
	}
	
	NSPoint origin = [window frame].origin;
	NSRect newFrame = NSMakeRect(origin.x, origin.y - heightDifference, [window frame].size.width, 
								 [window frame].size.height + heightDifference);
	[window setFrame:newFrame display:YES animate:YES];
}

- (void)setAdvancedViewHidden:(NSNumber*)value {
	[advancedView setHidden:[value boolValue]];
}

- (void)showAroundWindow:(NSWindow*)mainWindow resultDelegate:(id)aDelegate {
	if (!newPassphraseWindow) {
		if (![NSBundle loadNibNamed:@"PassphrasePicker" owner:self])  {
			NSLog(@"Failed to load PassphrasePicker.nib");
			NSBeep();
			return;
		}
	}
	
	resultDelegate = aDelegate;
	
	if (!keyDerivation) {
		keyDerivation = [[KeyDerivationManager alloc] initWithNotationPrefs:notationPrefs];
		[advancedView addSubview:[keyDerivation view]];
	}
	
	[newPasswordField setStringValue:@""];
	[verifyNewPasswordField setStringValue:@""];
	
	[rememberNewButton setState:[notationPrefs storesPasswordInKeychain]];
	[newPasswordField selectText:nil];
	
	[okNewButton setEnabled:NO];

	EnableSecureEventInput();
	
	[NSApp beginSheet:newPassphraseWindow modalForWindow:mainWindow modalDelegate:self 
	   didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	[newPasswordField setStringValue:@""];
	[verifyNewPasswordField setStringValue:@""];
	
	DisableSecureEventInput();
	
	if ([resultDelegate respondsToSelector:@selector(passphrasePicker:choseAPassphrase:)])
		[resultDelegate passphrasePicker:self choseAPassphrase:returnCode];
}


- (IBAction)cancelNewPassword:(id)sender {
	[NSApp endSheet:newPassphraseWindow returnCode:0];
	[newPassphraseWindow close];
}

- (IBAction)okNewPassword:(id)sender {
	NSString *pass = [newPasswordField stringValue];
	
	if ([pass isEqualToString:[verifyNewPasswordField stringValue]]) {
		
		[notationPrefs setPassphraseData:[pass dataUsingEncoding:NSUTF8StringEncoding] 
							  inKeychain:[rememberNewButton state] 
						  withIterations:[keyDerivation hashIterationCount]];
		
		[NSApp endSheet:newPassphraseWindow returnCode:1];
		[newPassphraseWindow close];
		
	} else {
		NSRunAlertPanel(NSLocalizedString(@"Your entered passphrase does not match your verify passphrase.",nil), 
						NSLocalizedString(@"Please try again.",nil), NSLocalizedString(@"OK",nil), nil, nil);
		[verifyNewPasswordField setStringValue:@""];
		[verifyNewPasswordField performSelector:@selector(selectText:) withObject:nil afterDelay:0.0];
	}
}

- (void)textDidChange:(NSNotification *)aNotification {
	[okNewButton setEnabled:(([[newPasswordField stringValue] length] > 0) && ([[verifyNewPasswordField stringValue] length] > 0))];
}

@end
