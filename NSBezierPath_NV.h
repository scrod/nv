//
//  NSBezierPath_NV.h
//  Notation
//
//  Created by Zachary Schneirov on 1/14/11.
//  Copyright 2011 Northwestern University. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface NSBezierPath (NV)

+ (NSBezierPath *)bezierPathWithRoundRectInRect:(NSRect)aRect radius:(float)radius;

+ (NSBezierPath *)bezierPathWithLayoutManager:(NSLayoutManager*)layoutManager characterRange:(NSRange)charRange atPoint:(NSPoint)point;

@end
