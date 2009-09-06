#import "PassphraseRetriever.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NSData_transformations.h"
#import "NSString_NV.h"
#import <Carbon/Carbon.h>

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
		NSString *resolvedPath = [NSString pathWithFSRef:&notesDirectoryRef];
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
	
	EnableSecureEventInput();
	int result = [NSApp runModalForWindow:window];
	DisableSecureEventInput();
	
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
	}	
}

@end
