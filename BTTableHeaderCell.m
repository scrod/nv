//
//  BTTableHeaderView.m
//
//  Created by Brett Terpstra on 12/13/10.
//  Copyright 2010 Circle Six Design. All rights reserved.
//

#import "BTTableHeaderCell.h"


@implementation BTTableHeaderCell


- (id)initTextCell:(NSString *)text
{
    if ((self = [super initTextCell:text])) {
        metalBg = [[NSImage imageNamed:@"tan_column_header.png"] retain];
        if (text == nil || [text isEqualToString:@""]) {
            [self setTitle:@"Title"];
        }
        [metalBg setFlipped:YES];
        attrs = [[NSMutableDictionary dictionaryWithDictionary:
				  [[self attributedStringValue] 
				   attributesAtIndex:0 
				   effectiveRange:NULL]] 
				 mutableCopy];
        return self;
    }
    return nil;
}


- (void)dealloc
{
    [metalBg release];
    [attrs release];
    [super dealloc];
}


- (void)drawWithFrame:(NSRect)inFrame inView:(NSView*)inView
{
    /* Draw metalBg lowest pixel along the bottom of inFrame. */
    NSRect tempSrc = NSZeroRect;
    tempSrc.size = [metalBg size];
    tempSrc.origin.y = tempSrc.size.height - 1.0;
    tempSrc.size.height = 1.0;
    
    NSRect tempDst = inFrame;
    tempDst.origin.y = inFrame.size.height - 1.0;
    tempDst.size.height = 1.0;
    
    [metalBg drawInRect:tempDst 
               fromRect:tempSrc 
              operation:NSCompositeSourceOver 
               fraction:1.0];
    
    /* Draw rest of metalBg along width of inFrame. */
    tempSrc.origin.y = 0.0;
    tempSrc.size.height = [metalBg size].height - 1.0;
    
    tempDst.origin.y = 1.0;
    tempDst.size.height = inFrame.size.height - 2.0;
    
    [metalBg drawInRect:tempDst 
               fromRect:tempSrc 
              operation:NSCompositeSourceOver 
               fraction:1.0];
    
    /* Draw white text centered, but offset down-left. */
    float offset = 0.5;
    [attrs setValue:[NSColor colorWithCalibratedWhite:1.0 alpha:0.7] 
             forKey:@"NSColor"];
    
    NSRect centeredRect = inFrame;
    centeredRect.size = [[self stringValue] sizeWithAttributes:attrs];
    centeredRect.origin.x += 
	((inFrame.size.width - centeredRect.size.width) / 2.0) - offset;
    centeredRect.origin.y = 
	((inFrame.size.height - centeredRect.size.height) / 2.0) + offset;
    [[self stringValue] drawInRect:centeredRect withAttributes:attrs];
    
    /* Draw black text centered. */
    [attrs setValue:[NSColor blackColor] forKey:@"NSColor"];
    centeredRect.origin.x += offset;
    centeredRect.origin.y -= offset;
    [[self stringValue] drawInRect:centeredRect withAttributes:attrs];
}


- (id)copyWithZone:(NSZone *)zone
{
    id newCopy = [super copyWithZone:zone];
    [metalBg retain];
    [attrs retain];
    return newCopy;
}


@end
