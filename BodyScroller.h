//
//  BodyScroller.h
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