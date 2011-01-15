//
//  BodyScroller.m
//  Notation
//
//  Created by Zachary Schneirov on 2/5/07.

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