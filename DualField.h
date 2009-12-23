/* DualField */

#import <Cocoa/Cocoa.h>

@interface DualFieldCell : NSTextFieldCell {}
@end

@interface DualField : NSTextField {
	IBOutlet NSTableView *notesTable;
	unsigned int lastLengthReplaced;
	NSButton *snapbackButton;
	NSString *snapbackString;
}

- (void)setSnapbackString:(NSString*)string;
- (void)_addSnapbackButtonForEditor:(NSText*)editor;
- (void)_addSnapbackButtonForView:(NSView*)view;
- (unsigned int)lastLengthReplaced;
+ (NSBezierPath*)bezierPathWithRoundRectInRect:(NSRect)aRect radius:(float)radius;
+ (NSImage*)snapbackImageWithString:(NSString*)string;

- (void)updateButtonIfNecessaryForEditor:(NSText*)editor;

- (NSMenu*)snapbackMenu;
@end
