//
//  ETTransparentScroller.h
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//
//	Modified by elasticthreads 10/19/2010
//

#import "ETTransparentScroller.h"
#import "ETContentView.h"

static NSImage *knobTop, *knobVerticalFill, *knobBottom, *slotTop, *slotVerticalFill, *slotBottom;
static float verticalPaddingLeft = 3.1f;
static float verticalPaddingRight = 3.1f;
static float verticalPaddingTop = 2.5f;
static float verticalPaddingBottom = 2.5f;
static float minKnobHeight;

//static NSColor *scrollBackgroundColor;

@interface ETTransparentScroller (NVTSPrivate)
- (void)drawKnobSlot;
@end

@interface NSScroller (NVTSPrivate)
- (NSRect)_drawingRectForPart:(NSScrollerPart)aPart;
@end

@implementation ETTransparentScroller

+ (void)initialize
{
	NSBundle *bundle = [NSBundle bundleForClass:[ETTransparentScroller class]];
	
	knobTop				= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerKnobTop.tif"]];
	knobVerticalFill	= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerKnobVerticalFill.tif"]];
	knobBottom			= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerKnobBottom.tif"]];
	slotTop				= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerSlotTop.tif"]];
	slotVerticalFill	= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerSlotVerticalFill.tif"]];
	slotBottom			= [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentScrollerSlotBottom.tif"]];
	
	//bwBackgroundColor	= [[NSColor colorWithCalibratedWhite:0.13 alpha:0.855] retain];
	//scrollBackgroundColor = [[NSColor colorWithCalibratedRed:0.948f green:0.948f blue:0.948f alpha:1.0f]retain];
	minKnobHeight = knobTop.size.height + knobVerticalFill.size.height + knobBottom.size.height + 10;
}

- (id)init{
	if ([super init]) {		
		[self setArrowsPosition:NSScrollerArrowsNone];	
	}
	return self;
}
/*
- (void)awakeFromNib{
	//lionStyle = YES;	
	//scrollBackgroundColor = [[NSColor colorWithCalibratedRed:0.948f green:0.948f blue:0.948f alpha:1.0f]retain];
}*/

+ (CGFloat)scrollerWidth
{
	return slotVerticalFill.size.width + verticalPaddingLeft + verticalPaddingRight;
}

+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)controlSize 
{
	return slotVerticalFill.size.width + verticalPaddingLeft + verticalPaddingRight;
}
/*
- (void)setBackgroundColor:(NSColor *)inColor {	
    NSLog(@"unnecessary");
    if (scrollBackgroundColor) {
        [scrollBackgroundColor release];
    }
	scrollBackgroundColor = inColor;
	[scrollBackgroundColor retain];
	//[[self enclosingScrollView] setNeedsDisplay:YES];
}

- (void)setLionStyle:(BOOL)isLion{
    NSLog(@"setting lionstyle: %d",isLion);
	lionStyle = isLion;
}*/

- (void)drawRect:(NSRect)aRect;
{
    
    if ([[[self superview] className] isEqualToString:@"ETScrollView"]) {
       // NSLog(@"notlion");
        NSDrawWindowBackground([self bounds]);
   //     [[[[self window] contentView] backgroundColor] setFill];
     //   NSRectFill([self bounds]);
	}
	//NSRectFillUsingOperation(aRect,NSCompositeSourceOut);//([self bounds]);
	// Only draw if the slot is larger than the knob
	if (([self bounds].size.height - verticalPaddingTop - verticalPaddingBottom + 1) > minKnobHeight)
	{
		[self drawKnobSlot];
		
		if ([self knobProportion] > 0.0)	
			[self drawKnob];
	}
    
}

- (void)drawKnobSlot;
{	
	NSRect slotRect = [self rectForPart:NSScrollerKnobSlot];
	NSDrawThreePartImage(slotRect, slotTop, slotVerticalFill, slotBottom, YES, NSCompositeSourceOver, 0.25f, NO);
}

- (void)drawKnob;
{
	NSRect knobRect = [self rectForPart:NSScrollerKnob];
	NSDrawThreePartImage(knobRect, knobTop, knobVerticalFill, knobBottom, YES, NSCompositeSourceOver, 0.5, NO);
}

- (NSRect)_drawingRectForPart:(NSScrollerPart)aPart;
{
	// Call super even though we're not using its value (has some side effects we need)
	[super _drawingRectForPart:aPart];
	
	// Return our own rects rather than use the default behavior
	return [self rectForPart:aPart];
}

- (NSRect)rectForPart:(NSScrollerPart)aPart;
{
    
	switch (aPart)
	{
		case NSScrollerNoPart:
			return [self bounds];
			break;
		case NSScrollerKnob:
		{		
			NSRect knobRect;
			NSRect slotRect = [self rectForPart:NSScrollerKnobSlot];	
			//NSLog(@"knobproportion is : %f",[self knobProportion]);
			
			float knobHeight = roundf(slotRect.size.height * [self knobProportion]*.993);
			
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
			
            
			slotRect = NSMakeRect(verticalPaddingLeft, verticalPaddingTop, [self bounds].size.width - verticalPaddingLeft - verticalPaddingRight, [self bounds].size.height - verticalPaddingTop - verticalPaddingBottom);
			
			slotRect.origin.y = (slotRect.origin.y + (slotRect.size.height * .0035));
			slotRect.size.height = (slotRect.size.height * .993);
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

#if DELAYED_LAYOUT
- (void)mouseDown:(NSEvent*)event {
	if (![contentViewDelegate readyToDraw]) {
		[contentViewDelegate _setFutureSelectionRangeWithinIndex:[[contentViewDelegate string] length]];
	}
	
	[super mouseDown:event];
}

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
#endif

@end
