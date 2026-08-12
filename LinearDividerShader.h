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


#import <Cocoa/Cocoa.h>

NSRect centeredRectInRect(NSRect rect, NSSize size);

@interface LinearDividerShader : NSObject  {
	CGColorSpaceRef	colorSpaceRef;
	NSColor *startColor, *endColor, *darkStartColor, *darkEndColor;
	NSImage *dimpleImage;
}

- (id)initWithStartColor:(NSColor*)start endColor:(NSColor*)end;
- (id)initWithStartColor:(NSColor*)start endColor:(NSColor*)end darkStartColor:(NSColor*)darkStart darkEndColor:(NSColor*)darkEnd;

- (void)drawDividerInRect:(NSRect)aRect withDimpleRect:(NSRect)dimpleRect blendVertically:(BOOL)v;

@end

@interface NSImage (CenteredDrawing)

- (void)drawCenteredInRect:(NSRect)aRect;
- (void)drawCenteredInRect:(NSRect)aRect fraction:(float)aFraction;
- (void)drawTemplateCenteredInRect:(NSRect)aRect color:(NSColor*)color fraction:(float)aFraction;

@end
