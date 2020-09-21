/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


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

- (void)drawDividerInRect:(NSRect)aRect withDimpleRect:(NSRect)dimpleRect blendVertically:(BOOL)v {

	CGShadingRef cgShading = CGShadingCreateAxial(colorSpaceRef, CGPointMake(aRect.origin.x, aRect.origin.y), 
												  CGPointMake(v ? NSMinX(aRect) : NSMaxX(aRect), v ? NSMaxY(aRect) : NSMinY(aRect)), 
												  axialShadingFunction, NO, NO);	
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
//	[self drawAtPoint:cent.origin fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:aFraction];
	[self compositeToPoint:NSMakePoint(cent.origin.x, cent.origin.y + cent.size.height) operation:NSCompositingOperationSourceOver fraction:aFraction];
}

@end
