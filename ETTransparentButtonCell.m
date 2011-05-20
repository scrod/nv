//
//  ETTransparentButtonCell.m
//  BWToolkit
//
//  Created by Brandon Walkin (www.brandonwalkin.com)
//  All code is provided under the New BSD license.
//

#import "ETTransparentButtonCell.h"

static NSImage *buttonLeftN, *buttonFillN, *buttonRightN, *buttonLeftP, *buttonFillP, *buttonRightP;
static NSColor *disabledColor, *enabledColor;

@interface NSCell (BWTBCPrivate)
- (NSDictionary *)_textAttributes;
@end

@interface ETTransparentButtonCell (BWTBCPrivate)
- (NSColor *)interiorColor;
@end

@implementation ETTransparentButtonCell

+ (void)initialize;
{
	NSBundle *bundle = [NSBundle bundleForClass:[ETTransparentButtonCell class]];
	
	buttonLeftN = [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentButtonLeftN.tiff"]];
	buttonFillN = [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentButtonFillN.tiff"]];
	buttonRightN = [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentButtonRightN.tiff"]];
	buttonLeftP = [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentButtonLeftP.tiff"]];
	buttonFillP = [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentButtonFillP.tiff"]];
	buttonRightP = [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"TransparentButtonRightP.tiff"]];

	enabledColor = [[NSColor whiteColor] retain];
	disabledColor = [[NSColor colorWithCalibratedWhite:0.6 alpha:1] retain];
}

- (void)drawBezelWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    
	cellFrame.size.height = buttonFillN.size.height;
	
	if ([self isHighlighted])
		NSDrawThreePartImage(cellFrame, buttonLeftP, buttonFillP, buttonRightP, NO, NSCompositeSourceOver, 1, YES);
	else
		NSDrawThreePartImage(cellFrame, buttonLeftN, buttonFillN, buttonRightN, NO, NSCompositeSourceOver, 1, YES);	
     
}

- (void)drawImage:(NSImage *)image withFrame:(NSRect)frame inView:(NSView *)controlView
{	
    frame.origin.y -= 2;
	
	if ([[image name] isEqualToString:@"NSActionTemplate"])
		[image setSize:NSMakeSize(10,10)];
	
	NSImage *newImage = image;
	if ([image isTemplate])
		newImage = [self bwTintedImage:image WithColor:[self interiorColor]];
	
	[super drawImage:newImage withFrame:frame inView:controlView];
}

- (NSRect)drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)controlView
{
	frame.origin.y -= 4;
	
	return [super drawTitle:title withFrame:frame inView:controlView];
}

- (NSDictionary *)_textAttributes
{
	NSMutableDictionary *attributes = [[[NSMutableDictionary alloc] init] autorelease];
	[attributes addEntriesFromDictionary:[super _textAttributes]];
	[attributes setObject:[NSFont systemFontOfSize:11] forKey:NSFontAttributeName];
	[attributes setObject:[self interiorColor] forKey:NSForegroundColorAttributeName];
	
	return attributes;
}

- (NSColor *)interiorColor
{
	NSColor *interiorColor;
	
	if ([self isEnabled])
		interiorColor = enabledColor;
	else
		interiorColor = disabledColor;
	
	return interiorColor;
}

- (NSControlSize)controlSize
{
	return NSSmallControlSize;
}

- (void)setControlSize:(NSControlSize)size
{
	
}

- (NSImage *)bwTintedImage:(NSImage *)anImage WithColor:(NSColor *)tint 
{
    
	NSSize size = [anImage size];
	NSRect imageBounds = NSMakeRect(0, 0, size.width, size.height);    
	
	NSImage *copiedImage = [anImage copy];
	
	[copiedImage lockFocus];
	
	[tint set];
	NSRectFillUsingOperation(imageBounds, NSCompositeSourceAtop);
	
	[copiedImage unlockFocus];  
	
	return [copiedImage autorelease];
}

@end
