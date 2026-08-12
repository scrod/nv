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


@implementation LinearDividerShader

- (id)initWithStartColor:(NSColor*)start endColor:(NSColor*)end {
	return [self initWithStartColor:start endColor:end darkStartColor:start darkEndColor:end];
}

- (id)initWithStartColor:(NSColor*)start endColor:(NSColor*)end darkStartColor:(NSColor*)darkStart darkEndColor:(NSColor*)darkEnd {
    
    if ((self = [super init])) {

		colorSpaceRef = CGColorSpaceCreateDeviceRGB();
		startColor = [start retain];
		endColor = [end retain];
		darkStartColor = [darkStart retain];
		darkEndColor = [darkEnd retain];
		
		dimpleImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForImageResource:@"SplitViewDimple.tif"]];
    }

    return self;
}

- (void)dealloc {

	CGColorSpaceRelease(colorSpaceRef);
	[startColor release];
	[endColor release];
	[darkStartColor release];
	[darkEndColor release];
	[dimpleImage release];
	
	[super dealloc];
}

- (void)drawDividerInRect:(NSRect)aRect withDimpleRect:(NSRect)dimpleRect blendVertically:(BOOL)v {
	BOOL dark = [[[NSAppearance currentDrawingAppearance] bestMatchFromAppearancesWithNames:
				  [NSArray arrayWithObjects:NSAppearanceNameAqua, NSAppearanceNameDarkAqua, nil]] isEqualToString:NSAppearanceNameDarkAqua];
	NSColor *resolvedStartColor = dark ? darkStartColor : startColor;
	NSColor *resolvedEndColor = dark ? darkEndColor : endColor;
	CGFloat components[8];
	[[resolvedStartColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]]
	 getRed:&components[0] green:&components[1] blue:&components[2] alpha:&components[3]];
	[[resolvedEndColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]]
	 getRed:&components[4] green:&components[5] blue:&components[6] alpha:&components[7]];

	CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpaceRef, components, NULL, 2);
	CGContextDrawLinearGradient([[NSGraphicsContext currentContext] CGContext], gradient,
		CGPointMake(aRect.origin.x, aRect.origin.y),
		CGPointMake(v ? NSMinX(aRect) : NSMaxX(aRect), v ? NSMaxY(aRect) : NSMinY(aRect)), 0);
	CGGradientRelease(gradient);
	
	if (!NSIsEmptyRect(dimpleRect)) {
		[dimpleImage drawTemplateCenteredInRect:dimpleRect color:[NSColor tertiaryLabelColor] fraction:1.0];
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


@implementation NSImage (CenteredDrawing)

- (void)drawCenteredInRect:(NSRect)aRect {
	[self drawCenteredInRect:aRect fraction:1.0];
}
- (void)drawCenteredInRect:(NSRect)aRect fraction:(float)aFraction {
	NSRect cent = centeredRectInRect(aRect, [self size]);
	cent = [[NSView focusView] centerScanRect:cent];
	[self drawInRect:cent
		fromRect:NSZeroRect
		operation:NSCompositingOperationSourceOver
		fraction:aFraction
		respectFlipped:YES
		hints:nil];
}

- (void)drawTemplateCenteredInRect:(NSRect)aRect color:(NSColor*)color fraction:(float)aFraction {
	NSImage *tintedImage = [NSImage imageWithSize:[self size] flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
		[self drawInRect:dstRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
			 fraction:1.0 respectFlipped:YES hints:nil];
		[color set];
		NSRectFillUsingOperation(dstRect, NSCompositingOperationSourceAtop);
		return YES;
	}];
	[tintedImage drawCenteredInRect:aRect fraction:aFraction];
}

@end
