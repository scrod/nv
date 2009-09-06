/* PassphrasePicker */

#import <Cocoa/Cocoa.h>

@class NotationPrefs;
@class KeyDerivationManager;

@interface PassphrasePicker : NSObject
{
    IBOutlet NSButton *cancelNewButton;
    IBOutlet NSPanel *newPassphraseWindow, *window;
    IBOutlet NSSecureTextField *newPasswordField;
    IBOutlet NSButton *okNewButton;
    IBOutlet NSButton *rememberNewButton;
    IBOutlet NSSecureTextField *verifyNewPasswordField;
	IBOutlet NSButton *disclosureButton;
	IBOutlet NSTextField *advancedHelpField;
	IBOutlet NSView *dismissalButtonsView, *upperButtonsView, *advancedView;
	
	KeyDerivationManager *keyDerivation;
	NotationPrefs *notationPrefs;
	id resultDelegate;
}

- (IBAction)discloseAdvancedSettings:(id)sender;

- (void)showAroundWindow:(NSWindow*)mainWindow resultDelegate:(id)aDelegate;
- (IBAction)cancelNewPassword:(id)sender;
- (IBAction)okNewPassword:(id)sender;

- (id)initWithNotationPrefs:(NotationPrefs*)prefs;
@end

@interface NSObject (PassphrasePickerDelegate)
- (void)passphrasePicker:(PassphrasePicker*)picker choseAPassphrase:(BOOL)success;
@end