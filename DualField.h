/* DualField */

#import <Cocoa/Cocoa.h>

enum { BUTTON_HIDDEN, BUTTON_NORMAL, BUTTON_PRESSED };

@interface DualFieldCell : NSTextFieldCell {
	int clearButtonState, snapbackButtonState;
}

- (BOOL)snapbackButtonIsVisible;
- (void)setShowsSnapbackButton:(BOOL)shouldShow;

- (BOOL)clearButtonIsVisible;
- (void)setShowsClearButton:(BOOL)shouldShow;

- (NSRect)clearButtonRectForBounds:(NSRect)rect;
- (NSRect)snapbackButtonRectForBounds:(NSRect)rect;
- (NSRect)textAreaForBounds:(NSRect)rect;

- (BOOL)handleMouseDown:(NSEvent *)theEvent;

@end

@interface DualField : NSTextField {
	IBOutlet NSTableView *notesTable;
	unsigned int lastLengthReplaced;
	NSString *snapbackString, *swappedOriginalString;
	
	NSToolTipTag docIconTag, textAreaTag, clearButtonTag;
	NSTrackingRectTag docIconRectTag;
	
	BOOL showsDocumentIcon;
}

- (void)setTrackingRect;

- (void)setShowsDocumentIcon:(BOOL)showsIcon;
- (BOOL)showsDocumentIcon;

- (void)setSnapbackString:(NSString*)string;
- (NSString*)snapbackString;
+ (NSImage*)snapbackImageWithString:(NSString*)string;

- (void)deselectAll:(id)sender;

- (unsigned int)lastLengthReplaced;
+ (NSBezierPath*)bezierPathWithRoundRectInRect:(NSRect)aRect radius:(float)radius;

@end
