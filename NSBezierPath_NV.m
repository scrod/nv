//
//  NSBezierPath_NV.m
//  Notation
//
//  Created by Zachary Schneirov on 1/14/11.
//  Copyright 2011 Northwestern University. All rights reserved.
//

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
	NSGlyph *glyphs = (NSGlyph *)malloc(sizeof(NSGlyph) * range.length * 2);
	[layoutManager getGlyphs:glyphs range:range];
		
	NSBezierPath *path = [NSBezierPath bezierPath];
	[path moveToPoint:point];
	[path appendBezierPathWithGlyphs:glyphs count:range.length inFont:[[layoutManager textStorage] font]];
	
	free(glyphs);
	
	return path;
}


@end
