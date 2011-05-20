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

typedef struct {

	union {
		struct {
			CGFloat redComp;
			CGFloat greenComp;
			CGFloat blueComp;
			CGFloat alphaComp;
		};
		CGFloat channels[4];
	} firstColor, secondColor;
	
} ColorSet;

NSRect centeredRectInRect(NSRect rect, NSSize size);

@interface LinearDividerShader : NSObject  {
	CGColorSpaceRef	colorSpaceRef;
	CGFunctionRef axialShadingFunction;
	NSColor *borderCol;
	NSColor *backCol;
	ColorSet colors;
	NSImage *dimpleImage;
}

- (id)initWithStartColor:(NSColor*)start endColor:(NSColor*)end;
- (id)initWithBaseColors:(id)sender;
- (void)updateColors:(NSColor *)startColor;
- (void)drawDividerInRect:(NSRect)aRect withDimpleRect:(NSRect)dimpleRect blendVertically:(BOOL)v;
- (void)setBackColor:(NSColor *)inColor;

@end

@interface NSImage (CenteredDrawing)

- (void)drawCenteredInRect:(NSRect)aRect;
- (void)drawCenteredInRect:(NSRect)aRect fraction:(float)aFraction;

@end
