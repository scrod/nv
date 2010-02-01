#import <Cocoa/Cocoa.h>

typedef struct {

	union {
		struct {
			CGFloat redComp;
			CGFloat greenComp;
			CGFloat blueComp;
			CGFloat alphaComp;
		};
		CGFloat channels[4];
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

@interface NSImage (CenteredDrawing)

- (void)drawCenteredInRect:(NSRect)aRect;
- (void)drawCenteredInRect:(NSRect)aRect fraction:(float)aFraction;

@end
