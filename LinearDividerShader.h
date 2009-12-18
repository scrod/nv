#import <Cocoa/Cocoa.h>

typedef struct {

	struct {
		CGFloat redComp;
		CGFloat greenComp;
		CGFloat blueComp;
		CGFloat alphaComp;
	} firstColor, secondColor;
	
} ColorSet;

NSRect centeredRectInRect(NSRect rect, NSSize size);

@interface LinearDividerShader : NSObject  {
	CGColorSpaceRef	colorSpaceRef;
	CGFunctionRef axialShadingFunction;
	
	ColorSet colors;
	NSImage *dimpleImage;
}

- (id)initWithStartColor:(NSColor*)start endColor:(NSColor*)end;

- (void)drawDividerInRect:(NSRect)aRect withDimpleRect:(NSRect)dimpleRect;

@end
