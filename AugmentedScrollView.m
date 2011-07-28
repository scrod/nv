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

#import "ETTransparentScroller.h"
#import "AugmentedScrollView.h"
#import "GlobalPrefs.h"



/*
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
*/

@implementation AugmentedScrollView


- (void)awakeFromNib {
	
	//dragSquare = [[DragSquareView alloc] initWithFrame:NSMakeRect(0, 0, 15.0, 15.0)];
	[[GlobalPrefs defaultPrefs] registerForSettingChange:@selector(setHorizontalLayout:sender:) withTarget:self];
    if (!IsLionOrLater) {
        [self setVerticalScroller:[[ETTransparentScroller alloc]init]];
    }
	/*
	if ((showDragSquare = [[GlobalPrefs defaultPrefs] horizontalLayout])) {
		//add dragsquare subview to this view
		[self addSubview:dragSquare positioned:NSWindowAbove relativeTo:self];
		[self _positionDragSquare];
	}*/
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
    
    if (!IsLionOrLater) {
    if ([selectorString isEqualToString:SEL_STR(setHorizontalLayout:sender:)]) {
		
		/*if ((showDragSquare = [[GlobalPrefs defaultPrefs] horizontalLayout])) {
			//add drag square
			[self addSubview:dragSquare positioned:NSWindowAbove relativeTo:self];
		} else {
			//remove drag square
			[dragSquare removeFromSuperview];
		}*/
		[self tile];
	}
    }
}

- (void)dealloc {
    
	//[dragSquare release];
	[super dealloc];
}
/*
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
	
	
}*/

- (void)tile {
	[super tile];
    if (!IsLionOrLater) {
        
        if (![[self verticalScroller] isHidden]) {
            NSRect vsRect = [[self verticalScroller] frame];
            NSRect conRect = [[self contentView] frame];
            NSView *wdContent = [[self contentView] retain];
            conRect.size.width = conRect.size.width + vsRect.size.width;
            [wdContent setFrame:conRect];
            [wdContent release];
            [[self verticalScroller] setFrame:vsRect];
            
        }
    }
	/*if (showDragSquare) {
		[self _positionDragSquare];
	}*/
}


@end
