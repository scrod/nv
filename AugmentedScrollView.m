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


#import "AugmentedScrollView.h"
#import "GlobalPrefs.h"


@implementation DragSquareView

- (id)initWithFrame:(NSRect)frameRect {
	if ((self = [super initWithFrame:frameRect]) != nil) {
		dragImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForImageResource:@"ListDividerDrag.png"]];
	}
	return self;
}

- (void)drawRect:(NSRect)rect {
	[dragImage compositeToPoint:rect.origin operation:NSCompositeCopy];

}

- (void)resetCursorRects {
	[self addCursorRect:[self bounds] cursor: [NSCursor resizeLeftRightCursor]];
}

- (BOOL)isOpaque {
	return YES;
}

- (void)dealloc {
	[dragImage release];
	[super dealloc];
}

@end


@implementation AugmentedScrollView


- (void)awakeFromNib {
	
	dragSquare = [[DragSquareView alloc] initWithFrame:NSMakeRect(0, 0, 15.0, 15.0)];
	[[GlobalPrefs defaultPrefs] registerForSettingChange:@selector(setHorizontalLayout:sender:) withTarget:self];
	
	if ((showDragSquare = [[GlobalPrefs defaultPrefs] horizontalLayout])) {
		//add dragsquare subview to this view
		[self addSubview:dragSquare positioned:NSWindowAbove relativeTo:self];
		[self _positionDragSquare];
	}
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
    
    if ([selectorString isEqualToString:SEL_STR(setHorizontalLayout:sender:)]) {
		
		if ((showDragSquare = [[GlobalPrefs defaultPrefs] horizontalLayout])) {
			//add drag square
			[self addSubview:dragSquare positioned:NSWindowAbove relativeTo:self];
		} else {
			//remove drag square
			[dragSquare removeFromSuperview];
		}
		[self tile];
	}
}

- (void)dealloc {
	[dragSquare release];
	[super dealloc];
}

- (BOOL)shouldDragWithPoint:(NSPoint)point sender:(id)sender {
	BOOL inRect = NSMouseInRect([dragSquare convertPoint:point fromView:sender], 
								[dragSquare bounds], [dragSquare isFlipped]);

	return showDragSquare && inRect;
}

- (void)_positionDragSquare {
	NSSize oldSize = [[self verticalScroller] frame].size;
	NSSize dragSize = [dragSquare frame].size;
	
	[[self verticalScroller] setFrameSize:NSMakeSize(oldSize.width, oldSize.height - dragSize.height)];
	
	NSRect newFrame = [[self verticalScroller] frame];
	[dragSquare setFrameOrigin:NSMakePoint(NSMaxX(newFrame) - dragSize.width, NSMaxY(newFrame))];
}

- (void)tile {
	[super tile];

	if (showDragSquare) {
		[self _positionDragSquare];
	}
}

@end
