/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import "EmptyView.h"
//#import "AppController.h"

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
	/*
	if (!bgCol) {
		bgCol = [[[NSApp delegate] backgrndColor] retain];
	}*/

}

- (void)mouseDown:(NSEvent*)anEvent {
	[[NSApp delegate] performSelector:@selector(bringFocusToControlField:) withObject:nil];
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

- (void)resetCursorRects {
	[self addCursorRect:[self bounds] cursor: [NSCursor arrowCursor]];
}

- (BOOL)isOpaque {	
	return NO;
}
/*
- (void)setBackgroundColor:(NSColor *)inColor{
	if (bgCol) {
		[bgCol release];
	}
	bgCol = inColor;
	[bgCol retain];
}

- (void)drawRect:(NSRect)rect {
	//NSRect bounds = [self bounds];
	if (!bgCol) {
		bgCol = [[[NSApp delegate] backgrndColor] retain];
	}
	//[bgCol set];
    //NSRectFill(bounds);
}
*/

@end
