//
//  WordCountToken.m
//  Notation
//
//  Created by ElasticThreads on 3/1/11.
//

#import "WordCountToken.h"
#import "AppController.h"
//#import <QuartzCore/QuartzCore.h>

@implementation WordCountToken

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
    }
    return self;
}

- (void)awakeFromNib{
	[self refusesFirstResponder];
	//theGrad =  [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.2f alpha:0.28f] endingColor:[NSColor colorWithCalibratedWhite:0.74f alpha:0.18f]] retain];
	
	//[self setTxtColor:[[NSApp delegate] foregrndColor]];
	//[self setFldColor:[[NSApp delegate] backgrndColor]];
	
}

- (void)mouseDown:(NSEvent *)theEvent{
	[[NSApp delegate] toggleWordCount:self];
}
/*
- (void)drawRect:(NSRect)dirtyRect {
	[super drawRect:dirtyRect];
	
	
	//[self resetCursorRects];
	//[[NSColor whiteColor] set];
	//NSRectFill([self bounds]);
	NSString *text = [self stringValue];
	if ([text isEqualToString:@""]) {
		[[NSApp delegate] updateWordCount];
	}
	static NSMutableParagraphStyle *alignStyle = nil;
	if (!alignStyle) {
		alignStyle = [[NSMutableParagraphStyle alloc] init];
		[alignStyle setAlignment:NSCenterTextAlignment];
	}
	NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:alignStyle, NSParagraphStyleAttributeName, [NSFont fontWithName:@"Helvetica" size:8.0f],NSFontAttributeName,txtColor,NSForegroundColorAttributeName, nil];
//	NSAttributedString *theStr = [NSAttributedString initWithString:text attributes:options];
	//[self setAttributedStringValue:theStr];
	NSRect labelRect = [text boundingRectWithSize:[self bounds].size options:nil attributes:options];
	NSRect aRect = labelRect;
	aRect.origin = [self bounds].origin;;
	

	aRect.origin.x = [self bounds].origin.x + [self bounds].size.width - aRect.size.width - 7.0f;
	
	 if ((aRect.size.width*1.9)>20.f) {
	 aRect.size.width = aRect.size.width*1.9;
	 }else {
	 aRect.size.width += 20.0f;
	 }
	//aRect.size.height = aRect.size.height *1.2f;
	CGFloat ht = aRect.size.height *.6;
	CGFloat wdth = aRect.size.width * .06;
	NSBezierPath *path1 = [NSBezierPath bezierPathWithRoundedRect:aRect xRadius:wdth yRadius:ht];
	[path1 setLineWidth:0.8f];
	[txtColor set];
	[path1 stroke];
	[fldColor set];
	[path1 fill];
	[theGrad drawInBezierPath:path1  angle:270.0f];
	
	labelRect = [text boundingRectWithSize:aRect.size options:nil attributes:options];
	NSPoint thePoint = aRect.origin;
	thePoint.x +=  (aRect.size.width - labelRect.size.width)/2.0f;
	thePoint.x -= 1.0f;
	[text drawAtPoint:thePoint withAttributes:options];
	
}
*/

/*
- (void)setTxtColor:(NSColor *)inColor{
	if (txtColor) {
		[txtColor release];
	}
	
	inColor = [NSColor whiteColor];
	CGFloat fWhite;		
	fWhite = [[inColor colorUsingColorSpaceName:NSCalibratedWhiteColorSpace] whiteComponent];
	/*if (fWhite < 0.62f) {
		if (fWhite<0.10f) {
			fWhite += 0.2f;
		}else {
			fWhite += 0.1f;
		}		
	}else {
		fWhite -= 0.1f;
	}
	txtColor = [NSColor colorWithCalibratedWhite:0.28f alpha:1.0f];
	//txtColor = inColor;
	[txtColor retain];
	[self setTextColor:txtColor];
}

- (void)setFldColor:(NSColor *)inColor{
	/*if (fldColor) {
		[fldColor release];
	}
	inColor = [NSColor lightGrayColor];
	CGFloat fWhite;		
	fWhite = [[[NSColor lightGrayColor] colorUsingColorSpaceName:NSCalibratedWhiteColorSpace] whiteComponent];
	/*if (fWhite > 0.25f) {
		if (fWhite>0.90f) {
			fWhite -= 0.25f;
		}else {
			fWhite -= 0.25f;
		}		
	}else {
		fWhite += 0.14f;
	}	
	fldColor = [NSColor colorWithCalibratedWhite:0.66f alpha:0.65f];
	
	//fldColor = [NSColor lightGrayColor];
	[fldColor retain];
}*/

/*
-(void)resetCursorRects
{
    // remove the existing cursor rects
    [self discardCursorRects];
    
    [self addCursorRect:[self visibleRect] cursor:[NSCursor arrowCursor]];
    
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent{
	return YES;
}*/

@end
