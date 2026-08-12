#import <Cocoa/Cocoa.h>
#import "../LinearDividerShader.h"
#import "../LinkingEditor.h"

static int failures = 0;

#define CHECK(__condition, __message) do { \
	if (!(__condition)) { \
		fprintf(stderr, "FAIL: %s\n", (__message)); \
		failures++; \
	} \
} while (0)

@interface LinkingEditor (AppearanceColorTest)
- (NSArray*)_displayColorsForForegroundColor:(NSColor*)foregroundColor backgroundColor:(NSColor*)backgroundColor;
@end

@interface LinkingEditor (AppearanceColorTestSetter)
- (void)_setScreenForegroundColorForTest:(NSColor*)color;
@end

@implementation LinkingEditor (AppearanceColorTestSetter)
- (void)_setScreenForegroundColorForTest:(NSColor*)color {
	[screenForegroundColor release];
	screenForegroundColor = [color retain];
}
@end

static BOOL ColorsMatch(NSColor *color, CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
	NSColor *rgbColor = [color colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
	CGFloat actualRed, actualGreen, actualBlue, actualAlpha;
	[rgbColor getRed:&actualRed green:&actualGreen blue:&actualBlue alpha:&actualAlpha];
	return fabs(actualRed - red) < 0.001 && fabs(actualGreen - green) < 0.001 &&
		fabs(actualBlue - blue) < 0.001 && fabs(actualAlpha - alpha) < 0.001;
}

static NSColor *DrawnDividerColor(LinearDividerShader *shader, NSAppearance *appearance) {
	NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:4
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
		bitmapFormat:0 bytesPerRow:0 bitsPerPixel:0] autorelease];
	NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
	NSGraphicsContext *previousContext = [NSGraphicsContext currentContext];
	[NSGraphicsContext setCurrentContext:context];
	[appearance performAsCurrentDrawingAppearance:^{
		[shader drawDividerInRect:NSMakeRect(0, 0, 4, 4) withDimpleRect:NSZeroRect blendVertically:YES];
	}];
	[NSGraphicsContext setCurrentContext:previousContext];
	return [rep colorAtX:2 y:2];
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	LinkingEditor *editor = [[[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)] autorelease];
	NSColor *customForeground = [NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.6 alpha:0.75];
	NSColor *customBackground = [NSColor colorWithCalibratedRed:0.9 green:0.8 blue:0.7 alpha:0.5];

	[editor setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];
	NSArray *displayColors = [editor _displayColorsForForegroundColor:customForeground backgroundColor:customBackground];
	CHECK(ColorsMatch([displayColors objectAtIndex:0], 0.2, 0.4, 0.6, 0.75) &&
		ColorsMatch([displayColors objectAtIndex:1], 0.9, 0.8, 0.7, 0.5), "light mode preserves custom colors");
	[editor setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
	displayColors = [editor _displayColorsForForegroundColor:customForeground backgroundColor:customBackground];
	CHECK(ColorsMatch([displayColors objectAtIndex:0], 0.9, 0.8, 0.7, 0.5) &&
		ColorsMatch([displayColors objectAtIndex:1], 0.2, 0.4, 0.6, 0.75), "dark mode swaps custom foreground and background colors");
	NSColor *systemColor = [NSColor textColor];
	NSColor *systemBackgroundColor = [NSColor textBackgroundColor];
	displayColors = [editor _displayColorsForForegroundColor:systemColor backgroundColor:systemBackgroundColor];
	CHECK([displayColors objectAtIndex:0] == systemColor && [displayColors objectAtIndex:1] == systemBackgroundColor,
		"dark mode leaves semantic system colors in their native order");

	[[editor textStorage] setAttributedString:[[[NSAttributedString alloc] initWithString:@"text"
		attributes:[NSDictionary dictionaryWithObject:customForeground forKey:NSForegroundColorAttributeName]] autorelease]];
	[editor _setScreenForegroundColorForTest:customBackground];
	NSDictionary *drawingAttributes = [editor layoutManager:[editor layoutManager]
		shouldUseTemporaryAttributes:[NSDictionary dictionary] forDrawingToScreen:YES atCharacterIndex:0 effectiveRange:NULL];
	CHECK(ColorsMatch([drawingAttributes objectForKey:NSForegroundColorAttributeName], 0.9, 0.8, 0.7, 0.5),
		"screen drawing substitutes the swapped foreground color");
	CHECK(ColorsMatch([[editor textStorage] attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL], 0.2, 0.4, 0.6, 0.75),
		"screen drawing leaves the stored foreground color unchanged");
	CHECK([editor layoutManager:[editor layoutManager] shouldUseTemporaryAttributes:[NSDictionary dictionary]
		forDrawingToScreen:NO atCharacterIndex:0 effectiveRange:NULL] == nil, "non-screen drawing uses stored colors");

	NSColor *lightGray = [NSColor colorWithWhite:0.9 alpha:1.0];
	NSColor *darkGray = [NSColor colorWithWhite:0.1 alpha:1.0];
	LinearDividerShader *shader = [[[LinearDividerShader alloc] initWithStartColor:lightGray endColor:lightGray
		darkStartColor:darkGray darkEndColor:darkGray] autorelease];
	CHECK([[DrawnDividerColor(shader, [NSAppearance appearanceNamed:NSAppearanceNameAqua])
		colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]] redComponent] > 0.8, "divider resolves its light appearance color while drawing");
	CHECK([[DrawnDividerColor(shader, [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua])
		colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]] redComponent] < 0.2, "divider resolves its dark appearance color while drawing");

	[pool drain];
	return failures == 0 ? 0 : 1;
}
