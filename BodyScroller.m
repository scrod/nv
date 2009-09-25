//
//  BodyScroller.m
//  Notation
//
//  Created by Zachary Schneirov on 2/5/07.
//  Copyright 2007 Zachary Schneirov. All rights reserved.
//

#import "BodyScroller.h"

#if DELAYED_LAYOUT

@implementation BodyScroller

- (void)awakeFromNib {
	rectForSuppressedUpdate = NSZeroRect;
}

/*- (void)drawRect:(NSRect)rect {
    // Drawing code here.
	
	if (!contentViewDelegate || [contentViewDelegate readyToDraw])
		[super drawRect:rect];
}*/

- (void)mouseDown:(NSEvent*)event {
	
	if (![contentViewDelegate readyToDraw]) {
		[contentViewDelegate _setFutureSelectionRangeWithinIndex:[[contentViewDelegate string] length]];
	}
		
	[super mouseDown:event];
}

/*
- (void)drawKnob {
	if ([contentViewDelegate readyToDraw]) {
		[super drawKnob];
	}
}*/

- (void)displayIfNeededInRect:(NSRect)aRect {
	if (![contentViewDelegate readyToDraw]) {
		rectForSuppressedUpdate = NSUnionRect(rectForSuppressedUpdate, aRect);
	} else {
		[super displayIfNeededInRect:aRect];
	}	
}

- (void)setNeedsDisplayInRect:(NSRect)invalidRect {
	if (![contentViewDelegate readyToDraw]) {
		rectForSuppressedUpdate = NSUnionRect(rectForSuppressedUpdate, invalidRect);
	} else {
		[super setNeedsDisplayInRect:invalidRect];
	}
}

- (void)clearSuppressedRects {
	rectForSuppressedUpdate = NSZeroRect;
}

- (void)restoreSuppressedRects {
	[super setNeedsDisplayInRect:rectForSuppressedUpdate];
}

- (void)setDisableUpdating:(BOOL)disable {
	disableUpdating = disable;
}
- (void)setContentViewDelegate:(id)aDelegate {
	contentViewDelegate = aDelegate;
}
- (id)contentViewDelegate {
	return contentViewDelegate;
}

@end
#endif