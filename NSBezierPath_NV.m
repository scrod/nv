//
//  NSBezierPath_NV.m
//  Notation
//
//  Created by Zachary Schneirov on 1/14/11.

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

#import "NSBezierPath_NV.h"


@implementation NSBezierPath (NV)

+ (NSBezierPath *)bezierPathWithRoundRectInRect:(NSRect)aRect radius:(float)radius  {
	NSBezierPath* path = [NSBezierPath bezierPath];
	float smallestEdge = MIN(NSWidth(aRect), NSHeight(aRect));
	radius = MIN(radius, 0.5f * smallestEdge);
	NSRect rect = NSInsetRect(aRect, radius, radius);
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMinX(rect), NSMinY(rect)) radius:radius startAngle:180.0 endAngle:270.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(rect), NSMinY(rect)) radius:radius startAngle:270.0 endAngle:360.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(rect), NSMaxY(rect)) radius:radius startAngle:  0.0 endAngle: 90.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMinX(rect), NSMaxY(rect)) radius:radius startAngle: 90.0 endAngle:180.0];
	[path closePath];
	return path;
}

+ (NSBezierPath *)bezierPathWithLayoutManager:(NSLayoutManager*)layoutManager characterRange:(NSRange)charRange atPoint:(NSPoint)point {
	NSRange range = [layoutManager glyphRangeForCharacterRange:charRange actualCharacterRange:NULL];
	CGGlyph *cgGlyphs = NULL;
	NSGlyph *glyphs = NULL;
	if (range.length > 0) {
		cgGlyphs = (CGGlyph *)malloc(sizeof(CGGlyph) * range.length);
		if (cgGlyphs) {
			[layoutManager getGlyphsInRange:range glyphs:cgGlyphs properties:NULL characterIndexes:NULL bidiLevels:NULL];
			glyphs = (NSGlyph *)malloc(sizeof(NSGlyph) * range.length);
			if (glyphs) {
				for (NSUInteger glyphIndex = 0; glyphIndex < range.length; glyphIndex++) {
					glyphs[glyphIndex] = (NSGlyph)cgGlyphs[glyphIndex];
				}
			}
		}
	}
	
	NSBezierPath *path = [NSBezierPath bezierPath];
	[path moveToPoint:point];
	if (glyphs && range.length > 0) {
		[path appendBezierPathWithGlyphs:glyphs count:range.length inFont:[[layoutManager textStorage] font]];
	}
	
	if (glyphs) {
		free(glyphs);
	}
	if (cgGlyphs) {
		free(cgGlyphs);
	}
	
	return path;
}


@end


@implementation NSImage (NV)

+ (NSImage*)smallIconForFileURL:(NSURL*)url {
	if (!url) return nil;
	NSImage *image = [[NSWorkspace sharedWorkspace] iconForFile:[url path]];
	[image setSize:NSMakeSize(16.0f, 16.0f)];
	return image;
}


@end
