//
//  TitlebarButton.h
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
