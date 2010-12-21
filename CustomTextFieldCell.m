//
//  customTextFieldCell.m
//  ControlPanel
//
//  Created by Han on 9/23/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import "CustomTextFieldCell.h"

#define kLeftMargin 5.0
#define kTopMargin 5.0

@implementation CustomTextFieldCell

//- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView*)controlView
//{
//	if([self isHighlighted]) {
//		[[NSColor colorWithCalibratedRed:0.131 green:0.297 blue:0.458 alpha:1.000] set];
//	} else {
//		[[NSColor colorWithCalibratedRed:0.709 green:0.791 blue:0.815 alpha:1.000] set];
//	}
//	cellFrame.size.width += 5;
//	NSRectFill(cellFrame);
//
////	[[self title] drawInRect:cellFrame withAttributes:nil];
//}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
	if( [self isHighlighted] ) {
		[[NSColor colorWithCalibratedRed:0.131 green:0.297 blue:0.458 alpha:1.000] set];
		NSRectFill(cellFrame);
//		[super drawWithFrame:cellFrame inView:controlView];
		NSColor *oldColor = [self textColor];
		[self setTextColor:[NSColor alternateSelectedControlTextColor]];
		[super drawWithFrame:cellFrame inView:controlView];
		[self setTextColor:oldColor];
	} else {
		[super drawWithFrame:cellFrame inView:controlView];
	}
}

- (NSColor *)highlightColorWithFrame:(NSRect)cellFrame inView:(NSView
															   *)controlView {
	return nil;
}
		 

		 
 - (void)drawInteriorWithFrame:(NSRect)cellFrame
				inView:(NSView *)controlView
{
	cellFrame.origin.x += kLeftMargin;
	cellFrame.size.width -= kLeftMargin;
	cellFrame.origin.y += kTopMargin;
	cellFrame.size.height -= kTopMargin;
	
	[super drawInteriorWithFrame:cellFrame
						  inView:controlView];
}
 
 - (void)selectWithFrame:(NSRect)aRect
				inView:(NSView *)controlView
				editor:(NSText *)textObj
			  delegate:(id)anObject
				 start:(NSInteger)selStart
				length:(NSInteger)selLength
{
	aRect.origin.x += kLeftMargin;
	aRect.size.width -= kLeftMargin;
	aRect.origin.y += kTopMargin;
	aRect.size.height -= kTopMargin;

	[super selectWithFrame:aRect
					inView:controlView
					editor:textObj
				  delegate:anObject
					 start:selStart
					length:selLength];
}
 
 - (NSRect)_focusRingFrameForFrame:(NSRect)frame
			 cellFrame:(NSRect)cellFrame
{
	return [[self controlView] bounds];
}

@end