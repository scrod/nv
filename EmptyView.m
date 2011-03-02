/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


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

- (void)mouseDown:(NSEvent*)anEvent {
	[[NSApp delegate] performSelector:@selector(_expandToolbar)];
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
	return YES;
}

- (void)drawRect:(NSRect)rect {
	NSRect bounds = [self bounds];
	
	[[NSColor whiteColor] set];
    NSRectFill(bounds);
	
	[[NSColor lightGrayColor] set];
    NSFrameRect(bounds);
}

@end
