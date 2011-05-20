//
//  ETTransparentButton based on
//  BWTransparentButton.m
//  BWToolkit
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//

#import "ETTransparentButton.h"
#import "ETTransparentButtonCell.h"

@implementation ETTransparentButton

- (id)initWithFrame:(NSRect)frameRect{
    if ((self = [super initWithFrame:frameRect]))
	{
        ETTransparentButtonCell *newCell = [[ETTransparentButtonCell alloc] init];
        [newCell setBezeled:YES];
        [newCell setBezelStyle:NSRecessedBezelStyle];
        [self setCell:newCell];
        [newCell release];
    }
	return self;
}

+ (Class) cellClass
{
     return [ETTransparentButtonCell class];
}

@end
