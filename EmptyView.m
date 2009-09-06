#import "EmptyView.h"
#import "AppController.h"

@implementation EmptyView

- (id)initWithFrame:(NSRect)frameRect {
	if ((self = [super initWithFrame:frameRect]) != nil) {
		// Add initialization code here
		
		lastNotesNumber = -1;
	}
	return self;
}

- (void)awakeFromNib {
	outletObjectAwoke(self);
}

- (void)setLabelStatus:(int)notesNumber {
	if (notesNumber != lastNotesNumber) {
		
		NSString *statusString = nil;
		if (notesNumber > 1) {
			statusString = [NSString stringWithFormat:NSLocalizedString(@"%d Notes Selected",nil), notesNumber];
		} else {
			statusString = NSLocalizedString(@"No Note Selected",nil); //\nPress return to create one.";
		}
		
		[labelText setStringValue:statusString];
		
		lastNotesNumber = notesNumber;
	}
}

- (void)drawRect:(NSRect)rect {
	NSRect bounds = [self bounds];
	
	[[NSColor whiteColor] set];
    NSRectFill(bounds);
	
	[[NSColor grayColor] set];
    NSFrameRect(bounds);
}

@end
