/* MultiTextFinder */

#import <Cocoa/Cocoa.h>
#define Backward NO
#define Forward YES

@interface MultiTextFinder : NSObject
{
    IBOutlet NSButton *entirePhraseButton;
    IBOutlet NSTextField *findStringField;
    IBOutlet NSButton *ignoreCaseButton;
    IBOutlet NSButton *nextButton;
    IBOutlet NSButton *previousButton;
    IBOutlet NSPanel *window;
	id delegate;
	BOOL lastFindWasSuccessful, findStringChangedSinceLastPasteboardUpdate;
	NSString *findString;
}

- (void)setDelegate:(id)aDelegate;
- (id)delegate;

- (IBAction)changeEntirePhrase:(id)sender;
- (IBAction)findNext:(id)sender;
- (IBAction)findPrevious:(id)sender;
@end
