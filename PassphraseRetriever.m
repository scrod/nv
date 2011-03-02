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


#import "PassphraseRetriever.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NSData_transformations.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"

@implementation PassphraseRetriever


+ (PassphraseRetriever *)retrieverWithNotationPrefs:(NotationPrefs*)prefs {
	PassphraseRetriever *retriever = [[PassphraseRetriever alloc] initWithNotationPrefs:prefs];
	return [retriever autorelease];
}

- (id)initWithNotationPrefs:(NotationPrefs*)prefs {
	if ([super init]) {
		notationPrefs = [prefs retain];
		
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[notationPrefs release];
	
	[super dealloc];
}

//1 for OK, 0 for cancelled, some other number for something else
- (int)loadedUserPassphraseData {
	
	if (!window) {
		if (![NSBundle loadNibNamed:@"PassphraseRetriever" owner:self])  {
			NSLog(@"Failed to load PassphraseRetriever.nib");
			NSBeep();
			return 0;
		}
	}
	
	NSString *startingDirectory = NSLocalizedString(@"the current notes directory",nil);
	FSRef notesDirectoryRef;
	
	if ([[[notationPrefs delegate] aliasDataForNoteDirectory] fsRefAsAlias:&notesDirectoryRef]) {
		NSString *resolvedPath = [[NSFileManager defaultManager] pathWithFSRef:&notesDirectoryRef];
		if (resolvedPath) startingDirectory = resolvedPath;
    }
	[helpStringField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Please enter the passphrase to access notes in %@.",nil), 
		[startingDirectory stringByAbbreviatingWithTildeInPath]]];	
	
	
	BOOL notationExists = [[GlobalPrefs defaultPrefs] notationPrefs] != nil;
	
	[cancelButton setKeyEquivalent: notationExists ? @"\033" : @"q"];
	[cancelButton setKeyEquivalentModifierMask: notationExists ? 0 : NSCommandKeyMask];
	[cancelButton setTitle: notationExists ? NSLocalizedString(@"Cancel",nil) : NSLocalizedString(@"Quit",nil)];
	[cancelButton setTarget: notationExists ? self : NSApp];
	[cancelButton setAction: notationExists ? @selector(cancelAction:) : @selector(terminate:)];
	[differentFolderButton setHidden: notationExists];

	[rememberKeychainButton setState:[notationPrefs storesPasswordInKeychain]];
	
	int result = [NSApp runModalForWindow:window];
	
	[passphraseField setStringValue:@""];
	[self textDidChange:nil];
	
	return result;
}

- (void)awakeFromNib {
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textDidChange:)
												 name:NSControlTextDidChangeNotification object:passphraseField];
}	

- (void)textDidChange:(NSNotification *)aNotification {
	[okButton setEnabled:([[passphraseField stringValue] length] > 0)];
}

- (IBAction)cancelAction:(id)sender {
	[NSApp stopModalWithCode:0];
	[window close];
}

- (IBAction)differentNotes:(id)sender {
	//ask the user to choose a different folder
	
	[NSApp stopModalWithCode:0];
	[window close];
}

- (IBAction)okAction:(id)sender {
	
	NSData *passData = [[passphraseField stringValue] dataUsingEncoding:NSUTF8StringEncoding];
	if ([notationPrefs canLoadPassphraseData:passData]) {
		
		if ([rememberKeychainButton state])
			[notationPrefs setKeychainData:passData];
		[notationPrefs setStoresPasswordInKeychain:[rememberKeychainButton state]];

		[NSApp stopModalWithCode:1];
		[window close];
		
	} else {
		NSBeginAlertSheet(NSLocalizedString(@"Sorry, you entered an incorrect passphrase.",nil), NSLocalizedString(@"OK",nil), 
						  nil, nil, window, nil, NULL, NULL, NULL, NSLocalizedString(@"Please try again.",nil));
		[passphraseField setStringValue:@""];
		[self textDidChange:nil];
	}	
}

@end
