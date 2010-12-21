//
//  NotesTableHeaderCell.m
//  Notation
//
//  Created by elasticthreads on 10/19/10.
//

#import "NotesTableHeaderCell.h"

NSColor *bColor;
NSColor *tColor;
NSColor *hColor;
NSGradient *gradient;

@implementation NotesTableHeaderCell

- (id)initTextCell:(NSString *)text
{
    if ((self = [super initTextCell:text])) {
		@try {
			//NSLog(@"headerCELL initing");
			if (!bColor) {
				bColor = [[NSColor whiteColor] retain];
				hColor = [[NSColor whiteColor] retain];
			}
			if (!tColor) {
				tColor = [[NSColor blackColor] retain];
			}
			gradient =  [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.93f alpha:0.3f] endingColor:[NSColor colorWithCalibratedWhite:0.12f alpha:0.25f]] retain];
			
		}
		@catch (NSException * e) {
			NSLog(@"init colors EXCEPT: %@",[e description]);
		}
		@finally {			
			if (text == nil || [text isEqualToString:@""]) {
				[self setTitle:@"Title"];
			}
			attrs = [[NSMutableDictionary dictionaryWithDictionary:
					  [[self attributedStringValue] 
					   attributesAtIndex:0 
					   effectiveRange:NULL]] 
					 mutableCopy];
			//NSLog(@"done initing");
			return self;
		}
    }
    return nil;
}

+ (void)setBackgroundColor:(NSColor *)inColor{
	bColor = [inColor retain];
	CGFloat fWhite;
	CGFloat endWhite;
	CGFloat fAlpha;
	NSColor	*gBack = [inColor colorUsingColorSpaceName:NSCalibratedWhiteColorSpace];
	[gBack getWhite:&fWhite alpha:&fAlpha];
	if (fWhite<0.5f) {
		endWhite = fWhite + .4f;
	}else {		
		endWhite = fWhite - .27f;
	}

	hColor = [[inColor blendedColorWithFraction:0.60f ofColor:[NSColor colorWithCalibratedWhite:endWhite alpha:0.98f]] retain];
}

+ (void)setForegroundColor:(NSColor *)inColor{
	tColor = [inColor retain];
}

- (void)drawWithFrame:(NSRect)inFrame inView:(NSView*)inView
{
	@try {
		//NSLog(@"draw frame");
		[[bColor copy]setFill];
		NSRectFill(inFrame);
		[gradient drawInRect:inFrame angle:90];
		@try {
			[tColor set];
			 NSBezierPath* thePath = [NSBezierPath bezierPath];
			 [thePath removeAllPoints];
			 [thePath moveToPoint:inFrame.origin];				
			 [thePath lineToPoint:NSMakePoint(inFrame.origin.x,(inFrame.origin.y +  inFrame.size.height))];	
			 [thePath lineToPoint:NSMakePoint((inFrame.origin.x + inFrame.size.width),(inFrame.origin.y +  inFrame.size.height))];
			// [thePath setLineWidth:2.0];
			[thePath setLineWidth:1.4];
			 [thePath stroke];
		}
		@catch (NSException * e) {
		NSLog(@"draw sides EXCEPT name: %@  description : %@",[e name],[e description]);
		}
		float offset = 5;  
		NSRect centeredRect = inFrame;
		centeredRect.size = [[self stringValue] sizeWithAttributes:attrs];
		//centeredRect.origin.x += ((inFrame.size.width - centeredRect.size.width) / 2.0); //- offset;
		centeredRect.origin.x += offset;
		centeredRect.origin.y = ((inFrame.size.height - centeredRect.size.height) / 2.0);
		// centeredRect.origin.y += offset/2;

		[attrs setValue:tColor forKey:@"NSColor"];
		[[self stringValue] drawInRect:centeredRect withAttributes:attrs];		
	}
	@catch (NSException * e) {
		NSLog(@"draw frame EXCEPT: %@",[e description]);
	}
	
}

- (void)drawSortIndicatorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView ascending:(BOOL)ascending priority:(NSInteger)priority{
	NSLog(@"draw sort");
}

- (void)highlight:(BOOL)hBool withFrame:(NSRect)inFrame inView:(NSView *)controlView{
	@try {
		if (hBool) {
			//NSLog(@"draw highlight");
			[hColor setFill];
			
		//	[NSBezierPath fillRect:inFrame];
			NSRectFill(inFrame);
			
			[gradient drawInRect:inFrame angle:90];
			@try {
				[tColor setStroke];
			//	NSLog(@"inFrame origin x is :%f  and y is : %f",inFrame.origin.x,inFrame.origin.y);
				NSBezierPath* thePath = [NSBezierPath bezierPath];
				[thePath removeAllPoints];
				[thePath moveToPoint:inFrame.origin];				
				[thePath lineToPoint:NSMakePoint(inFrame.origin.x,(inFrame.origin.y +  inFrame.size.height))];	
				[thePath lineToPoint:NSMakePoint((inFrame.origin.x + inFrame.size.width),(inFrame.origin.y +  inFrame.size.height))];
				//[thePath setLineWidth:2.0]; // Has no effect.
				[thePath setLineWidth:1.4];
				[thePath stroke];
			}
			@catch (NSException * e) {
				NSLog(@"draw highliths sides EXCEPT name: %@  description : %@",[e name],[e description]);
			}
			
			float offset = 5;
			[attrs setValue:bColor forKey:@"NSColor"];    
			NSRect centeredRect = inFrame;
			centeredRect.size = [[self stringValue] sizeWithAttributes:attrs]; 
			centeredRect.origin.x += offset;
			//centeredRect.origin.x += ((inFrame.size.width - centeredRect.size.width) / 2.0); 
			centeredRect.origin.y = ((inFrame.size.height - centeredRect.size.height) / 2.0); 			
			[attrs setValue:tColor forKey:@"NSColor"];
			[[self stringValue] drawInRect:centeredRect withAttributes:attrs];				
		}		
	}
	@catch (NSException * e) {
		NSLog(@"draw highlight EXCEPT: %@",[e description]);
	}		
}
/*
- (void)drawInteriorWithFrame:(NSRect)inFrame inView:(NSView *)controlView{

}*/

- (id)copyWithZone:(NSZone *)zone
{
    id newCopy = [super copyWithZone:zone];
    [attrs retain];
    return newCopy;
}

@end
