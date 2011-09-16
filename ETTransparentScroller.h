//
//  ETTransparentScroller.h
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//
//	Modified by elasticthreads 10/19/2010
//

#import <Cocoa/Cocoa.h>


@interface ETTransparentScroller : NSScroller {
    NSImage *knobTop, *knobVerticalFill, *knobBottom, *slotTop, *slotVerticalFill, *slotBottom;
    float verticalPaddingLeft;
    float verticalPaddingRight;
    float verticalPaddingTop;
    float verticalPaddingBottom;
    float minKnobHeight;
    float slotAlpha;
    float knobAlpha;
    BOOL isOverlay;
    BOOL fillBackground;
}

- (void)setFillBackground:(BOOL)fillIt;


@end

