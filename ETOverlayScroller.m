//
//  ETOverlayScroller.m
//  Notation
//
//  Created by elasticthreads on 9/15/11.
//  Copyright 2011 elasticthreads. All rights reserved.
//

#import "ETOverlayScroller.h"

@implementation ETOverlayScroller

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7
+ (BOOL)isCompatibleWithOverlayScrollers {
    return self == [ETOverlayScroller class];
}
#endif

- (id)initWithFrame:(NSRect)frameRect{
	if ((self=[super initWithFrame:frameRect])) {	
//        verticalPaddingLeft = 4.0f;
//        verticalPaddingRight = 2.75f;
        knobAlpha=0.7f;
        slotAlpha=0.55f;		
	}
	return self;
}


@end
