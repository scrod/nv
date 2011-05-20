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
		
		//dimpleImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForImageResource:@"SplitViewDimple.tif"]];
    }

    return self;
}

- (id)initWithBaseColors:(id)sender {
	if ((self = [super init])) {
		NSColor *endColor = [NSColor colorWithCalibratedWhite:0.875 alpha:1.0f];
		NSColor *oneColor = [NSColor colorWithCalibratedWhite:0.988 alpha:1.0f];
		
		colorSpaceRef = CGColorSpaceCreateDeviceRGB();
		
		[[oneColor colorUsingColorSpaceName:NSDeviceRGBColorSpace] getRed: &colors.firstColor.redComp green:&colors.firstColor.greenComp
																  blue:&colors.firstColor.blueComp alpha:&colors.firstColor.alphaComp];
		
		[[endColor colorUsingColorSpaceName:NSDeviceRGBColorSpace] getRed: &colors.secondColor.redComp green:&colors.secondColor.greenComp
																blue:&colors.secondColor.blueComp alpha:&colors.secondColor.alphaComp];
		
		static const CGFloat validIntervals[8] = { 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0 };
		static const CGFunctionCallbacks cgFunctionCallbacks = { 0, &ColorBlendFunction, nil };
		
		axialShadingFunction = CGFunctionCreate(&colors, 1, validIntervals, 4, validIntervals, &cgFunctionCallbacks);
		
		//dimpleImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForImageResource:@"SplitViewDimple.tif"]];
	}
	return self;
}

- (void)dealloc {

	CGFunctionRelease(axialShadingFunction);
	CGColorSpaceRelease(colorSpaceRef);
	[dimpleImage release];
	[borderCol release];	
	[backCol release];
	[super dealloc];
}

- (void)updateColors:(NSColor *)startColor{
    
    
	[backCol release];
	[borderCol release];
	backCol = [startColor retain];
	borderCol = [startColor colorUsingColorSpaceName:NSCalibratedWhiteColorSpace];	
	CGFloat fWhite;
	fWhite = [borderCol whiteComponent];
    
	NSColor *endColor;
	//CGFloat fWhite;
	//fWhite = [[startColor colorUsingColorSpaceName:NSCalibratedWhiteColorSpace] whiteComponent];
	dimpleImage = nil;
	[dimpleImage release];
	if (fWhite < 0.75f) {
		if (fWhite<0.15f) {
			fWhite += 0.2f;
			endColor = [NSColor colorWithCalibratedWhite:0.05f alpha:1.0f];
			startColor = [NSColor colorWithCalibratedWhite:0.18f alpha:1.0f];
		}else if (fWhite < 0.33) {	
			fWhite += 0.2f;		
			endColor = [NSColor colorWithCalibratedWhite:(fWhite - 0.12f) alpha:1.0f];
			startColor = [NSColor colorWithCalibratedWhite:(fWhite + 0.07f) alpha:1.0f];
		}else if (fWhite < 0.52) {	
			fWhite += 0.16f;		
			endColor = [NSColor colorWithCalibratedWhite:(fWhite - 0.15f) alpha:1.0f];
			startColor = [NSColor colorWithCalibratedWhite:(fWhite + 0.05f) alpha:1.0f];
		}else {
			fWhite += 0.16f;
			endColor = [NSColor colorWithCalibratedWhite:(fWhite - 0.2f) alpha:1.0f];
			startColor = [NSColor colorWithCalibratedWhite:(fWhite + 0.02f) alpha:1.0f];
		}	
	}else {		
		startColor = [NSColor colorWithCalibratedWhite:0.988 alpha:1.0f];
		endColor = [NSColor colorWithCalibratedWhite:0.875 alpha:1.0f];
		fWhite -= 0.25f;
		//dimpleImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForImageResource:@"SplitViewDimple.tif"]];
	}
    
	borderCol = [[NSColor colorWithCalibratedWhite:fWhite alpha:1.0f] retain];
	colorSpaceRef = CGColorSpaceCreateDeviceRGB();
	
	[[startColor colorUsingColorSpaceName:NSDeviceRGBColorSpace] getRed: &colors.firstColor.redComp green:&colors.firstColor.greenComp
																 blue:&colors.firstColor.blueComp alpha:&colors.firstColor.alphaComp];
	
	[[endColor colorUsingColorSpaceName:NSDeviceRGBColorSpace] getRed: &colors.secondColor.redComp green:&colors.secondColor.greenComp
																 blue:&colors.secondColor.blueComp alpha:&colors.secondColor.alphaComp];
	
	static const CGFloat validIntervals[8] = { 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0 };
	static const CGFunctionCallbacks cgFunctionCallbacks = { 0, &ColorBlendFunction, nil };
	
	axialShadingFunction = CGFunctionCreate(&colors, 1, validIntervals, 4, validIntervals, &cgFunctionCallbacks);
	
//	dimpleImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForImageResource:@"SplitViewDimple.tif"]];
}

- (void)drawDividerInRect:(NSRect)aRect withDimpleRect:(NSRect)dimpleRect blendVertically:(BOOL)v {
	if (!borderCol) {
		borderCol =[[NSColor grayColor] retain];
	}
	
	if ((aRect.origin.x==0)&&(aRect.origin.y==0)) {
		if (!backCol) {
			backCol = [[NSColor lightGrayColor] retain];
		}
		[backCol set];
		NSRectFill(aRect);
        
        if (aRect.size.width < aRect.size.height) {
			aRect.origin.y -=2;
			aRect.size.height += 4; 
			aRect.origin.x -=1;
			aRect.size.width += 1; 
		}else {
			aRect.origin.y -=1;
			aRect.size.height += 1; 
			aRect.origin.x -=2;
			aRect.size.width += 4; 
		}
        
		
        [borderCol set];
        NSFrameRectWithWidth(aRect,0.9f);
		
	}else {
		CGShadingRef cgShading = CGShadingCreateAxial(colorSpaceRef, CGPointMake(aRect.origin.x, aRect.origin.y), 
													  CGPointMake(v ? NSMinX(aRect) : NSMaxX(aRect), v ? NSMaxY(aRect) : NSMinY(aRect)), 
													  axialShadingFunction, NO, NO);	
		CGContextDrawShading((CGContextRef)[[NSGraphicsContext currentContext] graphicsPort], cgShading);
		
		CGShadingRelease(cgShading);		
		if (aRect.size.width < aRect.size.height) {
			aRect.origin.y -=2;
			aRect.size.height += 4; 
		}else {
			aRect.origin.x -=2;
			aRect.size.width += 4; 
		}

		
			[borderCol set];
			NSFrameRectWithWidth(aRect,0.8f);
		/*
		if (!NSIsEmptyRect(dimpleRect)&&(dimpleImage)) {
			[dimpleImage drawCenteredInRect:dimpleRect];
		}*/
	}

	
}

- (void)setBackColor:(NSColor *)inColor{
	[backCol release];
	[borderCol release];
	backCol = [inColor retain];
	borderCol = [inColor colorUsingColorSpaceName:NSCalibratedWhiteColorSpace];	
	CGFloat fWhite;
	fWhite = [borderCol whiteComponent];
	if (fWhite < 0.75f) {
		if (fWhite<0.25f) {
			fWhite += 0.2f;
		}else {
			fWhite += 0.16f;
		}		
	}else {
		fWhite -= 0.25f;
	}	
	borderCol = [[NSColor colorWithCalibratedWhite:fWhite alpha:1.0f] retain];
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
