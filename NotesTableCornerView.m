//
//  NVCornerView.m
//  Notation
//
//  Created by elasticthreads on 10/20/10.
//

#import "NotesTableCornerView.h"

NSColor *bColor;
NSColor *fColor;
NSGradient *cGradient;

@implementation NotesTableCornerView

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
		if (!bColor) {
			bColor = [NSColor lightGrayColor];
		}
		if (!fColor) {
			fColor = [NSColor darkGrayColor];
		}
		cGradient = [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.93f alpha:0.3f] endingColor:[NSColor colorWithCalibratedWhite:0.12f alpha:0.25f]] retain];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
	@try {		
		[bColor set];
		NSRectFill(dirtyRect);
		[cGradient drawInRect:dirtyRect angle:270];
		
		[fColor setStroke];
		NSBezierPath* thePath = [NSBezierPath bezierPath];
		[thePath removeAllPoints];
		[thePath moveToPoint:NSMakePoint(dirtyRect.origin.x,(dirtyRect.origin.y+dirtyRect.size.height))];				
		[thePath lineToPoint:dirtyRect.origin];	
		[thePath lineToPoint:NSMakePoint((dirtyRect.origin.x + dirtyRect.size.width),dirtyRect.origin.y)];
		[thePath setLineWidth:1.4]; // Has no effect.
		[thePath stroke];
		
	}
	@catch (NSException * e) {
		NSLog(@"drawrect except is : %@",[e description]);
	}
}

+ (void)setBackColor:(NSColor *)inColor{
	bColor = inColor;
}

+ (void)setBordColor:(NSColor *)inColor{
	fColor = inColor;
}

@end
