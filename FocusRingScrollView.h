/* FocusRingScrollView */

#import <Cocoa/Cocoa.h>

@interface FocusRingScrollView : NSScrollView
{
	BOOL hasFocus;
	NSWindow *window;
}

- (void)windowChangedKeyNotification:(NSNotification*)aNote;
- (void)setHasFocus:(BOOL)value;

@end
