//
//  ETTransparentScroller.h
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//
//	Modified by elasticthreads 10/19/2010
//

#import "ETTransparentScroller.h"

@interface NSScroller (NVTSPrivate)
- (NSRect)_drawingRectForPart:(NSScrollerPart)aPart;
@end

@implementation ETTransparentScroller

//+ (void)initialize
//{
//}

- (id)initWithFrame:(NSRect)frameRect{
	if ((self=[super initWithFrame:frameRect])) {	
        fillBackground=NO;
        NSBundle *bundle = [NSBundle mainBundle];
        
        knobTop				= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerKnobTop.tif"]];
        knobVerticalFill	= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerKnobVerticalFill.tif"]];
        knobBottom			= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerKnobBottom.tif"]];
        slotTop				= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerSlotTop.tif"]];
        slotVerticalFill	= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerSlotVerticalFill.tif"]];
        slotBottom			= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerSlotBottom.tif"]];
       verticalPaddingLeft = 3.0f;
       verticalPaddingRight = 3.75f;
       verticalPaddingTop =3.75f;
       verticalPaddingBottom = 4.25f;
       minKnobHeight = knobTop.size.height + knobVerticalFill.size.height + knobBottom.size.height + 25.0;
        slotAlpha=0.45f;
        knobAlpha=0.45f;
		[self setArrowsPosition:NSScrollerArrowsNone];
        
        isOverlay=NO;        
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7
        if (IsLionOrLater) {
            isOverlay=[[self class]isCompatibleWithOverlayScrollers];
        }
#endif
	}
	return self;
}

- (void)dealloc{
    [knobTop release];
    [knobVerticalFill release];
    [knobBottom release];
    [slotTop release];
    [slotBottom release];
    [slotVerticalFill release];
    [super dealloc];
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7
+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)controlSize scrollerStyle:(NSScrollerStyle)scrollerStyle{
    return 15.0;
}
//
+ (NSScrollerStyle)preferredScrollerStyle{
    return NSScrollerStyleOverlay;
}


//+ (BOOL)isCompatibleWithOverlayScrollers {
//    return self == [ETTransparentScroller class];
//}
#else
+ (CGFloat)scrollerWidth
{
	return 15.0;//slotVerticalFill.size.width + verticalPaddingLeft + verticalPaddingRight;
}
+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)controlSize 
{
	return 15.0;//slotVerticalFill.size.width + verticalPaddingLeft + verticalPaddingRight;
}
#endif

- (void)setFillBackground:(BOOL)fillIt{
    fillBackground=fillIt;
}

- (void)drawRect:(NSRect)aRect;
{       
        // Only draw if the slot is larger than the knob
    if (IsLionOrLater) {
        [super drawRect:aRect];
    }else{
        if (fillBackground) {
            [[[[self window] contentView] backgroundColor] setFill];
            NSRectFill([self bounds]);
        }
        if (([self bounds].size.height - verticalPaddingTop - verticalPaddingBottom + 1) > minKnobHeight)
        {
            [self drawKnobSlotInRect:[self rectForPart:NSScrollerKnobSlot] highlight:NO];
            
            if ([self knobProportion] > 0.0)	
                [self drawKnob];
        }
    }
}

- (void)drawKnobSlotInRect:(NSRect)slotRect highlight:(BOOL)flag{
    if (isOverlay) {
        [super drawKnobSlotInRect:slotRect highlight:flag];
    }else{
        NSDrawThreePartImage(slotRect, slotTop, slotVerticalFill, slotBottom, YES, NSCompositeSourceOver, slotAlpha, NO);
    }
}

- (void)drawKnob;
{
	NSRect knobRect = [self rectForPart:NSScrollerKnob];
    
	NSDrawThreePartImage(knobRect, knobTop, knobVerticalFill, knobBottom, YES, NSCompositeSourceOver, knobAlpha, NO);
   
}
//
- (NSRect)_drawingRectForPart:(NSScrollerPart)aPart;
{
	// Call super even though we're not using its value (has some side effects we need)
	[super _drawingRectForPart:aPart];
	
	// Return our own rects rather than use the default behavior
	return [self rectForPart:aPart];
}

//- (NSScrollerPart)testPart:(NSPoint)aPoint{
//    NSScrollerPart aPart=[super testPart:aPoint];
//    if (aPart==NSScrollerKnobSlot) {
//        NSLog(@"super found knobslot");
//    }else if (aPart==NSScrollerKnob) {
//        NSLog(@"super found knob");
//    }else{
//        NSLog(@"suer found else:%lu",aPart);
//    }
//    if (NSPointInRect(aPoint, [self rectForPart:NSScrollerKnob])) {
//        NSLog(@"knob");
//    }else if (NSPointInRect(aPoint, [self rectForPart:NSScrollerKnobSlot])) {
//        NSLog(@"knobsliot");
//        return NSScrollerKnobSlot;
//    }
//    NSLog(@"aqui");
//    return NSScrollerNoPart;
//}

//- (void)trackKnob:(NSEvent *)theEvent{
//    NSPoint aPoint=[theEvent locationInWindow];
//    NSScrollerPart aPart=[super testPart:aPoint];
//     NSLog(@"trackThis :>%lu<",aPart);
//    [super trackKnob:theEvent];
//}

- (NSRect)rectForPart:(NSScrollerPart)aPart;
{
    
	switch (aPart)
	{
		case NSScrollerNoPart:
        {
            NSLog(@"aquie");
			return [self bounds];
			break;
		}
        case NSScrollerKnob:
		{		
			NSRect knobRect;
			NSRect slotRect = [self rectForPart:NSScrollerKnobSlot];	
			
			float knobHeight = roundf(slotRect.size.height * [self knobProportion]);
            
			if (knobHeight < minKnobHeight)
				knobHeight = minKnobHeight;
			
			float knobY = slotRect.origin.y + roundf((slotRect.size.height - knobHeight) * [self floatValue]);
			knobRect = NSMakeRect(verticalPaddingLeft, knobY, slotRect.size.width, knobHeight);
            
			
			return knobRect;
		}
			break;	
		case NSScrollerKnobSlot:
		{
			NSRect slotRect;
			
            
			slotRect = NSMakeRect(verticalPaddingLeft,verticalPaddingTop,roundf([self bounds].size.width - verticalPaddingLeft - verticalPaddingRight), roundf([self bounds].size.height - verticalPaddingTop - verticalPaddingBottom));
			return slotRect;
		}
			break;
		case NSScrollerIncrementLine:
			return NSZeroRect;
			break;
		case NSScrollerDecrementLine:
			return NSZeroRect;
			break;
		case NSScrollerIncrementPage:
		{
			NSRect incrementPageRect;
			NSRect knobRect = [self rectForPart:NSScrollerKnob];
			NSRect slotRect = [self rectForPart:NSScrollerKnobSlot];
			NSRect decPageRect = [self rectForPart:NSScrollerDecrementPage];
            
			float knobY = knobRect.origin.y + knobRect.size.height;	
			incrementPageRect = NSMakeRect(verticalPaddingLeft, knobY, knobRect.size.width, slotRect.size.height - knobRect.size.height - decPageRect.size.height);
            
			return incrementPageRect;
		}
			break;
		case NSScrollerDecrementPage:
		{
			NSRect decrementPageRect;
			NSRect knobRect = [self rectForPart:NSScrollerKnob];
			
            
			decrementPageRect = NSMakeRect(verticalPaddingLeft, verticalPaddingTop, knobRect.size.width, knobRect.origin.y - verticalPaddingTop);
            
			return decrementPageRect;
		}
			break;
		default:
			break;
	}
	
	return NSZeroRect;
}

@end
