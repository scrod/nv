//
//  BodyScroller.h
//  Notation
//
//  Created by Zachary Schneirov on 2/5/07.
//  Copyright 2007 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "LinkingEditor.h"

#if DELAYED_LAYOUT

@interface BodyScroller : NSScroller {
	float actualProportion, actualPosition;
	id contentViewDelegate;
	NSRect rectForSuppressedUpdate;
	BOOL disableUpdating;
}

- (void)setDisableUpdating:(BOOL)disable;

- (void)clearSuppressedRects;
- (void)restoreSuppressedRects;

- (void)setContentViewDelegate:(id)aDelegate;
- (id)contentViewDelegate;

@end
#endif