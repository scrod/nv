//
//  BTTransparentScroller.m
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//
//  Modified by Brett Terpstra on 12/8/10.
//  Copyright 2010 Circle Six Design. All rights reserved.
//
// Modified again by ElasticThreads on 03/10/11

#import <Cocoa/Cocoa.h>

@interface BTTransparentScroller : NSScroller {
	BOOL isVertical;

}
-(void)setBackgroundColor:(NSColor*)bgcolor;

@end
