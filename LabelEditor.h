/* LabelEditor */

#import <Cocoa/Cocoa.h>

@interface LabelEditor : NSTextView {
	IBOutlet NSTextField *controlField;
	IBOutlet NSView *labelsLabel;
	NSCharacterSet *illegalTagCharacters;
}
@end
