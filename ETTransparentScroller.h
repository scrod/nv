//
//  ETTransparentScroller.h
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//
//	Modified by elasticthreads 10/19/2010
//

#import <Cocoa/Cocoa.h>
//#import "LinkingEditor.h"



@interface ETTransparentScroller : NSScroller 
{
	#if DELAYED_LAYOUT
	float actualProportion, actualPosition;
	id contentViewDelegate;
	NSRect rectForSuppressedUpdate;
	BOOL disableUpdating;
	#endif
	//NSColor *scrollBackgroundColor;
	//BOOL lionStyle;
}
#if DELAYED_LAYOUT
- (void)setDisableUpdating:(BOOL)disable;

- (void)clearSuppressedRects;
- (void)restoreSuppressedRects;

- (void)setContentViewDelegate:(id)aDelegate;
- (id)contentViewDelegate;

#endif
//- (void)setLionStyle:(BOOL)isLion;
//- (void)setBackgroundColor:(NSColor *)inColor;

@end

