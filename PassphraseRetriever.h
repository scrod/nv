/* PassphraseRetriever */

#import <Cocoa/Cocoa.h>

@class NotationPrefs;

@interface PassphraseRetriever : NSObject
{
    IBOutlet NSTextField *helpStringField;
    IBOutlet NSButton *okButton, *differentFolderButton, *cancelButton;
    IBOutlet NSTextField *passphraseField;
    IBOutlet NSButton *rememberKeychainButton;
    IBOutlet NSPanel *window;
	NotationPrefs *notationPrefs;

}

+ (PassphraseRetriever *)retrieverWithNotationPrefs:(NotationPrefs*)prefs;
- (id)initWithNotationPrefs:(NotationPrefs*)prefs;
- (int)loadedUserPassphraseData;
- (IBAction)cancelAction:(id)sender;
- (IBAction)differentNotes:(id)sender;
- (IBAction)okAction:(id)sender;
@end
