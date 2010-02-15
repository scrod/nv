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


#import "LinearDividerShader.h"


static void ColorBlendFunction(void *info, const CGFloat *in, CGFloat *out);

@implementation LinearDividerShader

- (id)initWithStartColor:(NSColor*)start endColor:(NSColor*)end {
    
    if ((self = [super init])) {

		colorSpaceRef = CGColorSpaceCreateDeviceRGB();
		
		[[start colorUsingColorSpaceName:NSDeviceRGBColorSpace] getRed: &colors.firstColor.redComp green:&colors.firstColor.greenComp
																  blue:&colors.firstColor.blueComp alpha:&colors.firstColor.alphaComp];
		
		[[end colorUsingColorSpaceName:NSDeviceRGBColorSpace] getRed: &colors.secondColor.redComp green:&colors.secondColor.greenComp
																blue:&colors.secondColor.blueComp alpha:&colors.secondColor.alphaComp];
		
		static const CGFloat validIntervals[8] = { 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0 };
		static const CGFunctionCallbacks cgFunctionCallbacks = { 0, &ColorBlendFunction, nil };
		
		axialShadingFunction = CGFunctionCreate(&colors, 1, validIntervals, 4, validIntervals, &cgFunctionCallbacks);
		
		dimpleImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForImageResource:@"SplitViewDimple.tif"]];
    }

    return self;
}

- (void)dealloc {

	CGFunctionRelease(axialShadingFunction);
	CGColorSpaceRelease(colorSpaceRef);
	[dimpleImage release];
	
	[super dealloc];
}

- (void)drawDividerInRect:(NSRect)aRect withDimpleRect:(NSRect)dimpleRect {

	CGShadingRef cgShading = CGShadingCreateAxial(colorSpaceRef, CGPointMake(aRect.origin.x, aRect.origin.y), 
												  CGPointMake(NSMinX(aRect), NSMaxY(aRect)), axialShadingFunction, NO, NO);
	
	CGContextDrawShading((CGContextRef)[[NSGraphicsContext currentContext] graphicsPort], cgShading);
	
	CGShadingRelease(cgShading);
	
	if (!NSIsEmptyRect(dimpleRect)) {
		[dimpleImage drawCenteredInRect:dimpleRect];
	}
}

@end

NSRect centeredRectInRect(NSRect rect, NSSize size) {
	NSRect centerRect;
	centerRect.size = size;
	centerRect.origin = NSMakePoint((rect.size.width - size.width) / 2.0,
									(rect.size.height - size.height) / 2.0);
	centerRect.origin = NSMakePoint(rect.origin.x + centerRect.origin.x, rect.origin.y + centerRect.origin.y);
	return centerRect;
}


void ColorBlendFunction(void *info, const CGFloat *in, CGFloat *out) {
	ColorSet* colors = (ColorSet *)info;
	
	float inVal = in[0];
	
	unsigned int i;
	for (i=0; i<4; i++) out[i] = (1.0 - inVal) * colors->firstColor.channels[i] + inVal * colors->secondColor.channels[i];
}


@implementation NSImage (CenteredDrawing)

- (void)drawCenteredInRect:(NSRect)aRect {
	[self drawCenteredInRect:aRect fraction:1.0];
}
- (void)drawCenteredInRect:(NSRect)aRect fraction:(float)aFraction {
	NSRect cent = centeredRectInRect(aRect, [self size]);
	cent = [[NSView focusView] centerScanRect:cent];
	[self compositeToPoint:NSMakePoint(cent.origin.x, cent.origin.y + cent.size.height) operation:NSCompositeSourceOver fraction:aFraction];
}

@end
