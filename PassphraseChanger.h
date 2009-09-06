/* PassphraseChanger */

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
