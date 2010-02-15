//
//  TitlebarButton.m
//  Notation
//

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


#import "TitlebarButton.h"
#import "LinearDividerShader.h"

@implementation TitlebarButtonCell

- (id)initTextCell:(NSString *)stringValue pullsDown:(BOOL)pullDown {
	if ([super initTextCell:stringValue pullsDown:pullDown]) {
		[self setBordered:NO];
		[self setArrowPosition:NSPopUpNoArrow];
	}
	return self;
}

- (void)handleRotationTimer:(NSTimer*)aTimer {
	rotationStep = (rotationStep + 1) % 16;
	[[self controlView] setNeedsDisplay:YES];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
	//[super drawWithFrame:cellFrame inView:controlView];

	if (NoIcon == iconType) return;

	NSEventType eventType = [[[controlView window] currentEvent] type];
	//shouldn't the cell already know when it's being pressed?
	BOOL isHighlighted = (isHovering && (eventType == NSLeftMouseDown || eventType == NSRightMouseDown ||
										 eventType == NSLeftMouseDragged || eventType == NSRightMouseDragged));
	
	if (isHighlighted) {
		[[NSImage imageNamed:@"TBMousedownBG"] drawCenteredInRect:cellFrame];
	} else if (isHovering) {
		[[NSImage imageNamed:@"TBRolloverBG"] drawCenteredInRect:cellFrame];
	}
	
	static NSString *normalImages[] = { nil, @"TBDownArrow", @"TBSynchronizing", @"TBAlert" };
	static NSString *whiteImages[] = { nil, @"TBDownArrowWhite", @"TBSynchronizingWhite", @"TBAlertWhite" };

	NSImage *img = [NSImage imageNamed: isHovering ? whiteImages[iconType] : normalImages[iconType] ];
	[img setFlipped:YES];
	
	if (SynchronizingIcon == iconType) {
		
		//use animation steps from 1 to 8 (rotationStep)
		
		NSPoint center = NSMakePoint([img size].width/2.0, [img size].height/2.0);
		NSAffineTransform *translateTransform = [NSAffineTransform transform];
		[translateTransform translateXBy:center.x yBy:center.y];
		[translateTransform rotateByRadians:((float)rotationStep / 16.0) * M_PI];
		[translateTransform translateXBy:-(center.x) yBy:-(center.y)];
		
		[NSGraphicsContext saveGraphicsState];
		[translateTransform concat];
	}
	
	NSRect imgRect = NSMakeRect(0, 0, [img size].width, [img size].height);
	[img drawInRect:imgRect fromRect:NSZeroRect operation:NSCompositeSourceOver 
		   fraction:isHovering ? 1.0 : ([[controlView window] isMainWindow] ? 0.83 : 0.5)];

	
	if (SynchronizingIcon == iconType) {
		[NSGraphicsContext restoreGraphicsState];
	}
	
}


- (BOOL)showsBorderOnlyWhileMouseInside {
	return YES;
}


- (void)mouseEntered:(NSEvent *)theEvent {
	isHovering = YES;
	[[self controlView] setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)theEvent {
	isHovering = NO;
	[[self controlView] setNeedsDisplay:YES];
}

- (void)setIsHovering:(BOOL)hovering {
	isHovering = hovering;
}

- (void)setStatusIconType:(TitleBarButtonIcon)anIconType {

	iconType = anIconType;
	if (!synchronizingTimer && SynchronizingIcon == iconType) {
		rotationStep = 0;
		synchronizingTimer = [[NSTimer timerWithTimeInterval:0.065 target:self selector:@selector(handleRotationTimer:) 
													userInfo:nil repeats:YES] retain];
		[[NSRunLoop currentRunLoop] addTimer:synchronizingTimer forMode:(NSString*)kCFRunLoopCommonModes];

	} else if (SynchronizingIcon != iconType) {
		[synchronizingTimer invalidate];
		[synchronizingTimer release];
		synchronizingTimer = nil;
	}
	//instead of using setHidden: when type is set to NoIcon, use setEnabled:
	//hiding the button can confuse the window

	[self setEnabled:NoIcon != iconType];
}

- (TitleBarButtonIcon)iconType {
	return iconType;
}

@end


@implementation TitlebarButton

+ (Class)cellClass {
	return [TitlebarButtonCell class];
}

- (id)initWithFrame:(NSRect)frameRect pullsDown:(BOOL)flag {
	if ([super initWithFrame:NSMakeRect(frameRect.origin.x, frameRect.origin.y, 17.0, 17.0) pullsDown:flag]) {
		
		TitlebarButtonCell *buttonCell = [[[TitlebarButtonCell alloc] initTextCell:@"" pullsDown:flag] autorelease];
		[buttonCell setAction:[[self cell] action]];
		[buttonCell setTarget:[[self cell] target]];
		[self setCell:buttonCell];
		
		[buttonCell setControlSize:NSSmallControlSize];
		[buttonCell setPullsDown:flag];
		[self setFont:[NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSSmallControlSize]]];
		[self setShowsBorderOnlyWhileMouseInside:YES];
		[self setBordered:NO];
		[self setPullsDown:flag];
		[self setTitle:@""];
		[self setEnabled:NO]; //consistent with NoIcon
		[self setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
		
		_initialDragPoint = NSMakePoint(-1, -1);
	}
	return self;
}

- (void)addToWindow:(NSWindow*)aWin {
	NSButton* closeButton = [aWin standardWindowButton:NSWindowCloseButton];
	NSView* superview = [closeButton superview];
	NSRect rc = [closeButton frame];
	[self setFrameOrigin:NSMakePoint(NSMaxX([superview bounds]) - rc.origin.x - rc.size.width, rc.origin.y + 1.0)];
	[superview addSubview:self];
	
	//work around a problem with mouseentered/exited events on tiger:
	//http://lists.apple.com/archives/cocoa-dev/2007/Jul/msg00142.html
	[self setShowsBorderOnlyWhileMouseInside:NO];
	[self setShowsBorderOnlyWhileMouseInside:YES];
}


- (void)mouseUp:(NSEvent*)event {
	_initialDragPoint = NSMakePoint(-1, -1);
	[super mouseUp:event];
}

- (void)mouseDragged:(NSEvent*)event {
	if (![self isEnabled]) {
		//allow dragging when button is "hidden"; if we actually removed the button from its superview--even at any time, 
		//titlebar-dragging behavior would dominate even when it returned; so use surrogate dragging behavior instead

		if (0 <= _initialDragPoint.x && 0 <= _initialDragPoint.y) {
			NSWindow *win = [self window];
			NSPoint p = [win convertBaseToScreen:[event locationInWindow]];
			NSRect sr = [[win screen] frame];
			NSRect wr = [win frame];
			
			NSPoint origin = NSMakePoint(p.x - _initialDragPoint.x, p.y - _initialDragPoint.y);
			if (NSMaxY(sr) < origin.y + wr.size.height) {
				origin.y = sr.origin.y + (sr.size.height - wr.size.height);
			}
			[win setFrameOrigin:origin];
		}
	} else {
		[super mouseDragged:event];
	}
}



- (void)mouseDown:(NSEvent *)theEvent {
		
	NSRect frame = [[self window] frame];
    _initialDragPoint = [[self window] convertBaseToScreen:[theEvent locationInWindow]];
    _initialDragPoint.x -= frame.origin.x;
    _initialDragPoint.y -= frame.origin.y;
	
	//on 10.4 prevent the menu from appearing until mouse-up
	
	if (IsLeopardOrLater) {
		[super mouseDown:theEvent];
		return;
	}
    while (1) {
        theEvent = [[self window] nextEventMatchingMask: NSLeftMouseUpMask | NSLeftMouseDraggedMask | 
					NSRightMouseUpMask | NSRightMouseDragged];
		NSEventType type = [theEvent type];
		
		if (type == NSLeftMouseUp || type == NSRightMouseUp) {
			
			if ([self mouse:[self convertPoint:[theEvent locationInWindow] fromView:nil] inRect:[self bounds]]) {
				[[self cell] performClickWithFrame:[self bounds] inView:self];
			}
			break;
		}		
    }	
}

- (BOOL)mouseDownCanMoveWindow {
	return NO;
}

- (void)setStatusIconType:(TitleBarButtonIcon)anIconType {
	if ([[self cell] iconType] != anIconType) {
		[[self cell] setStatusIconType:anIconType];
		if ([self superview]) {
			[self setNeedsDisplay:YES];
		}
	}
}

@end
