#import "LinearDividerShader.h"


static void ColorBlendFunction(void *info, const CGFloat *in, CGFloat *out);

@implementation LinearDividerShader

- (id)initWithStartColor:(NSColor*)start endColor:(NSColor*)end {
    
    if ((self = [super init])) {

		colorSpaceRef = CGColorSpaceCreateDeviceRGB();
		
		[[start colorUsingColorSpaceName:NSDeviceRGBColorSpace] getRed: &colors.firstColor.redComp green:&colors.firstColor.greenComp
																  blue:&colors.firstColor.blueComp alpha:&colors.firstColor.alphaComp];
		
		[[end colorUsingColorSpaceName:NSDeviceRGBColorSpace] getRed: &colors.secondColor.redComp green:&colors.secondColor.greenComp
																blue:&colors.secondColor.blueComp alpha:&colors.secondColor.alphaComp];
		
		static const CGFloat validIntervals[8] = { 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0 };
		static const CGFunctionCallbacks cgFunctionCallbacks = { 0, &ColorBlendFunction, nil };
		
		axialShadingFunction = CGFunctionCreate(&colors, 1, validIntervals, 4, validIntervals, &cgFunctionCallbacks);
		
		dimpleImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForImageResource:@"SplitViewDimple.tif"]];
		[dimpleImage setFlipped:YES];
    }

    return self;
}

- (void)dealloc {

	CGFunctionRelease(axialShadingFunction);
	CGColorSpaceRelease(colorSpaceRef);
	[dimpleImage release];
	
	[super dealloc];
}

- (void)drawDividerInRect:(NSRect)aRect withDimpleRect:(NSRect)dimpleRect {

	CGShadingRef cgShading = CGShadingCreateAxial(colorSpaceRef, CGPointMake(aRect.origin.x, aRect.origin.y), 
												  CGPointMake(NSMinX(aRect), NSMaxY(aRect)), axialShadingFunction, NO, NO);
	
	CGContextDrawShading((CGContextRef)[[NSGraphicsContext currentContext] graphicsPort], cgShading);
	
	CGShadingRelease(cgShading);
	
	if (!NSEqualRects(dimpleRect, NSZeroRect)) {
		//NSRect destRect = NSMakeRect(0.0, 0.0, dimpleRect.size.width, dimpleRect.size.height);
		[dimpleImage drawInRect:dimpleRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
	}
}

@end



void ColorBlendFunction(void *info, const CGFloat *in, CGFloat *out) {
	ColorSet* colors = (ColorSet *)info;
	
	float inVal = in[0];
	
	out[0] = (1.0 - inVal) * colors->firstColor.redComp + inVal * colors->secondColor.redComp;
	out[1] = (1.0 - inVal) * colors->firstColor.greenComp + inVal * colors->secondColor.greenComp;
	out[2] = (1.0 - inVal) * colors->firstColor.blueComp + inVal * colors->secondColor.blueComp;
	out[3] = (1.0 - inVal) * colors->firstColor.alphaComp + inVal * colors->secondColor.alphaComp;
}
