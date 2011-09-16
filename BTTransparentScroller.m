//
//  BTTransparentScroller.m
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//
//  Modified by Brett Terpstra on 12/8/10.
//  Copyright 2010 Circle Six Design. All rights reserved.
//
// Modified again by ElasticThreads on 03/10/11


#import "BTTransparentScroller.h"



@implementation BTTransparentScroller

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7

+ (BOOL)isCompatibleWithOverlayScrollers {
    return self == [BTTransparentScroller class];
}
#endif

- (id)initWithFrame:(NSRect)frameRect{
	if ((self=[super initWithFrame:frameRect])) {	        
        NSBundle *bundle = [NSBundle mainBundle];        
        knobTop				= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"greyscrollerverttop3.tif"]];
        knobVerticalFill	= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"greyscrollervertfill3.tif"]];
        knobBottom			= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"greyscrollervertbottom3.tif"]];
        slotTop				= [NSImage imageNamed:nil];
        slotVerticalFill	= [NSImage imageNamed:nil];
        slotBottom			= [NSImage imageNamed:nil];
        verticalPaddingLeft = 5.0f;
        verticalPaddingRight = 4.0f;
        verticalPaddingTop = 3.5f;
        verticalPaddingBottom = 3.5f;
        knobAlpha=0.95f;        
	}
	return self;
}

- (void)drawKnobSlotInRect:(NSRect)slotRect highlight:(BOOL)flag{
    if (!IsLionOrLater) {
        [[NSColor whiteColor]set];
        NSRectFill([self bounds]);        
    }else{
        [super drawKnobSlotInRect:slotRect highlight:flag];
    }
}

@end
