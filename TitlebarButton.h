//
//  TitlebarButton.h
//  Notation
//
//  Created by Zachary Schneirov on 1/25/10.
//  Copyright 2010 Northwestern University. All rights reserved.
//

#import <Cocoa/Cocoa.h>

typedef enum { NoIcon, DownArrowIcon, SynchronizingIcon, AlertIcon } TitleBarButtonIcon;

@interface TitlebarButtonCell : NSPopUpButtonCell {
	TitleBarButtonIcon iconType;
	BOOL isHovering;
	NSUInteger rotationStep;
	
	NSTimer *synchronizingTimer;
}

- (TitleBarButtonIcon)iconType;

- (void)setIsHovering:(BOOL)hovering;
- (void)setStatusIconType:(TitleBarButtonIcon)anIconType;

@end

@interface TitlebarButton : NSPopUpButton {
	NSPoint _initialDragPoint;
}

- (void)setStatusIconType:(TitleBarButtonIcon)anIconType;

- (void)addToWindow:(NSWindow*)aWin;
@end
