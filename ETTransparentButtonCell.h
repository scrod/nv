//
//  BWTransparentButtonCell.h
//  BWToolkit
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//

#import <Cocoa/Cocoa.h>
#import "ETTransparentButton.h"

@interface ETTransparentButtonCell : NSButtonCell 
{

}

- (NSImage *)bwTintedImage:(NSImage *)anImage WithColor:(NSColor *)tint;

@end
