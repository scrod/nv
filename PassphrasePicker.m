/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#import "PassphrasePicker.h"
#import "NotationPrefs.h"
#import "KeyDerivationManager.h"

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
	
	[NSApp beginSheet:newPassphraseWindow modalForWindow:mainWindow modalDelegate:self 
	   didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	[newPasswordField setStringValue:@""];
	[verifyNewPasswordField setStringValue:@""];
		
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
