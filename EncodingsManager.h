/* EncodingsManager */

#import <Cocoa/Cocoa.h>

@class NoteObject;

@interface EncodingsManager : NSObject
{
    IBOutlet NSPopUpButton *encodingsPopUpButton;
	IBOutlet NSButton *okButton;
    IBOutlet NSPanel *window;
	IBOutlet NSTextView *textView;
	IBOutlet NSTextField *helpStringField;
	
	NSStringEncoding currentEncoding;
	NoteObject *note;
	NSData *noteData;
	FSRef fsRef;
}

+ (EncodingsManager *)sharedManager;
- (BOOL)checkUnicode;
- (BOOL)tryToUpdateTextForEncoding:(NSStringEncoding)encoding;
- (BOOL)shouldUpdateNoteFromDisk;
- (void)showPanelForNote:(NoteObject*)aNote;
- (NSMenu*)textConversionsMenu;
- (IBAction)cancelAction:(id)sender;
- (IBAction)chooseEncoding:(id)sender;
- (IBAction)okAction:(id)sender;
@end
