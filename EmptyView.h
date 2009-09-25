/* EmptyView */

#import <Cocoa/Cocoa.h>

@interface EmptyView : NSView
{
    IBOutlet NSTextField *labelText;
	int lastNotesNumber;
}

- (void)setLabelStatus:(int)notesNumber;

@end
