// http://www.cocoadev.com/index.pl?PasswordAssistant

#import <Cocoa/Cocoa.h>

@interface SFPasswordAsstView : NSView
{
}

@end

@interface SFPasswordAssistantInspectorController : NSObject
{
	@public
    IBOutlet NSWindow *_baseWindow;
    NSWindow *_passwordAssistantPanel;
    SFPasswordAsstView *_passwordAssistantView;
    IBOutlet NSTextField *_originalPassword;
    IBOutlet NSTextField *_newPassword;
    IBOutlet NSTextField *_verifyPassword;
    NSTextField *_extOriginalPassword;
    NSTextField *_extNewPassword;
    NSTextField *_extVerifyPassword;
}

- (id)init;
- (void)dealloc;
- (void)loadOurNib;
- (IBAction)showPasswordAssistantPanel:(id)fp8;
- (void)baseWindowWillClose:(id)fp8;
- (void)windowDidEndSheet:(id)fp8;
- (void)ourPanelWillClose:(id)fp8;
- (id)baseWindow;
- (void)setBaseWindow:(id)fp8;
- (void)setOriginalPasswordField:(id)fp8;
- (void)setNewPasswordField:(id)fp8;
- (void)setVerifyPasswordField:(id)fp8;

@end

