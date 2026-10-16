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

@interface PassphraseRetriever (Private)
- (void)_setPassphraseEntryBusy:(BOOL)busy;
- (void)_finishOkActionWithCandidateMasterKey:(NSData*)candidateMasterKey passphraseData:(NSData*)passData
	remember:(BOOL)remember;
@end

@implementation PassphraseRetriever


+ (PassphraseRetriever *)retrieverWithNotationPrefs:(NotationPrefs*)prefs {
	PassphraseRetriever *retriever = [[PassphraseRetriever alloc] initWithNotationPrefs:prefs];
	return [retriever autorelease];
}

- (id)initWithNotationPrefs:(NotationPrefs*)prefs {
	self = [super init];
	if (self) {
		notationPrefs = [prefs retain];
		
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	[notationPrefs release];
	[passphraseRetrieverTopLevelObjects release];

	[super dealloc];
}

//1 for OK, 0 for cancelled, some other number for something else
- (int)loadedUserPassphraseData {
	
	if (!window) {
		NSArray *topLevelObjects = nil;
		if (![[NSBundle mainBundle] loadNibNamed:@"PassphraseRetriever" owner:self topLevelObjects:&topLevelObjects])  {
			NSLog(@"Failed to load PassphraseRetriever.nib");
			NSBeep();
			return 0;
		}
		[passphraseRetrieverTopLevelObjects release];
		passphraseRetrieverTopLevelObjects = [topLevelObjects retain];
	}
	
	NSString *startingDirectory = NSLocalizedString(@"the current notes directory",nil);
	NSURL *directoryURL = [[notationPrefs delegate] noteDirectoryURL];
	if ([directoryURL path]) startingDirectory = [directoryURL path];
	[helpStringField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Please enter the passphrase to access notes in %@.",nil), 
		[startingDirectory stringByAbbreviatingWithTildeInPath]]];	
	
	
	BOOL notationExists = [[GlobalPrefs defaultPrefs] notationPrefs] != nil;
	
	[cancelButton setKeyEquivalent: notationExists ? @"\033" : @"q"];
	[cancelButton setKeyEquivalentModifierMask: notationExists ? 0 : NSEventModifierFlagCommand];
	[cancelButton setTitle: notationExists ? NSLocalizedString(@"Cancel",nil) : NSLocalizedString(@"Quit",nil)];
	[cancelButton setTarget: notationExists ? self : NSApp];
	[cancelButton setAction: notationExists ? @selector(cancelAction:) : @selector(terminate:)];
	[differentFolderButton setHidden: notationExists];

	[rememberKeychainButton setState:[notationPrefs storesPasswordInKeychain]];
	
		NSInteger result = [NSApp runModalForWindow:window];
	// Closing this panel only tells the window server to remove it; that removal is carried out on a later turn
	// of this thread's run loop, which the caller does not otherwise return to before it starts decrypting and
	// unarchiving the whole note database -- several blocking seconds for a large database. Briefly running the
	// run loop here lets the window server finish removing the panel before that work ever begins; without it,
	// the panel stays genuinely on screen for the whole wait and is only actually removed once the wait ends.
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

	[passphraseField setStringValue:@""];
	[self textDidChange:nil];
	
		return (int)result;
}

- (void)awakeFromNib {

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textDidChange:)
												 name:NSControlTextDidChangeNotification object:passphraseField];
	// Closing this panel is immediately followed by the main thread decrypting and unarchiving the whole note
	// database, synchronously and without returning to the run loop -- several seconds for a large database.
	// A system-animated close left mid-flight when that work starts can resurface the panel once the main
	// thread frees up and the run loop resumes; an unanimated close finishes before that work ever begins.
	[window setAnimationBehavior:NSWindowAnimationBehaviorNone];

	if (@available(macOS 26.0, *)) {
		// Tahoe's push-button bezel draws wider than the nominal frame the nib laid out for it, so two buttons
		// placed with the older, narrower bezel in mind now visually touch even though neither button's frame
		// has moved. Pin a fixed visual gap between them directly, rather than leaving it to whatever margin the
		// nib happened to leave for the previous bezel; earlier macOS versions already space them adequately
		// and are left untouched.
		const CGFloat desiredButtonGap = 12.0;
		NSRect cancelFrame = [cancelButton frame];
		NSRect okFrame = [okButton frame];
		cancelFrame.origin.x = NSMinX(okFrame) - desiredButtonGap - cancelFrame.size.width;
		[cancelButton setFrame:cancelFrame];
	}

	// A small spinner, shown only while the key-derivation hash in -okAction: runs on a background queue.
	// Its iteration count is deliberately calibrated (see KeyDerivationManager) to a user-chosen duration of up
	// to several seconds, as a brute-force-resistance cost factor, so this dialog needs its own visible sign of
	// life during that wait instead of appearing frozen. It sits inset in the passphrase field's own trailing
	// edge, inside that field's bounds, rather than beside a button row whose exact layout this class does not
	// otherwise depend on, so it can never land on top of a button.
	if (!keyDerivationSpinner) {
		NSRect fieldFrame = [passphraseField frame];
		const CGFloat spinnerSize = 16.0, inset = 4.0;
		NSRect spinnerFrame = NSMakeRect(NSMaxX(fieldFrame) - spinnerSize - inset,
			NSMidY(fieldFrame) - spinnerSize / 2.0, spinnerSize, spinnerSize);
		keyDerivationSpinner = [[NSProgressIndicator alloc] initWithFrame:spinnerFrame];
		[keyDerivationSpinner setStyle:NSProgressIndicatorStyleSpinning];
		[keyDerivationSpinner setControlSize:NSControlSizeSmall];
		[keyDerivationSpinner setDisplayedWhenStopped:NO];
		[[passphraseField superview] addSubview:keyDerivationSpinner];
	}
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

- (void)_setPassphraseEntryBusy:(BOOL)busy {
	// passphraseField is deliberately left enabled throughout: by the time this fires, it already holds first
	// responder and the field's own focus ring, and disabling it -- even briefly -- resigns that first-responder
	// status, which AppKit does not restore on its own once the field is re-enabled.
	[okButton setEnabled:!busy && [[passphraseField stringValue] length] > 0];
	[cancelButton setEnabled:!busy];
	[differentFolderButton setEnabled:!busy];
	[rememberKeychainButton setEnabled:!busy];
	if (busy) [keyDerivationSpinner startAnimation:nil];
	else [keyDerivationSpinner stopAnimation:nil];
}

- (IBAction)okAction:(id)sender {

	NSData *passData = [[passphraseField stringValue] dataUsingEncoding:NSUTF8StringEncoding];
	BOOL remember = [rememberKeychainButton state];

	// The hash below is deliberately slow by design (see KeyDerivationManager), so it runs on a background queue
	// and only the pure, stateless derivation happens there; notationPrefs is read but never mutated off the
	// main thread. This keeps this panel's run loop turning for the whole wait -- the spinner animates, Cancel
	// still responds -- instead of freezing visibly for however long this database was calibrated to take.
	[self _setPassphraseEntryBusy:YES];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSData *candidateMasterKey = [notationPrefs derivedMasterKeyCandidateFromPassphraseData:passData];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self _setPassphraseEntryBusy:NO];
			[self _finishOkActionWithCandidateMasterKey:candidateMasterKey passphraseData:passData remember:remember];
		});
	});
}

- (void)_finishOkActionWithCandidateMasterKey:(NSData*)candidateMasterKey passphraseData:(NSData*)passData
	remember:(BOOL)remember {

	if ([notationPrefs acceptMasterKeyIfValid:candidateMasterKey]) {

		if (remember)
			[notationPrefs setKeychainData:passData];
		[notationPrefs setStoresPasswordInKeychain:remember];

		[NSApp stopModalWithCode:1];
		[window close];

	} else {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:NSLocalizedString(@"Sorry, you entered an incorrect passphrase.", nil)];
		[alert setInformativeText:NSLocalizedString(@"Please try again.", nil)];
		[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
		[alert beginSheetModalForWindow:window completionHandler:nil];
		[passphraseField setStringValue:@""];
		[self textDidChange:nil];
	}	
}

@end
