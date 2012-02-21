//
//  ETContentView.m
//  Notation
//
//  Created by elasticthreads on 3/15/11.
//

#import "ETContentView.h"
#import "AppController.h"

@implementation ETContentView

//- (id)initWithFrame:(NSRect)frame
//{
//    self = [super initWithFrame:frame];
//    if (self) {
//        // Initialization code here.
//    }
//    
//    return self;
//}
//
//- (void)dealloc
//{
//    [super dealloc];
//}

//- (void)mouseUp:(NSEvent *)theEvent{
//    //    [[NSApp delegate] resetModTimers];
//    NSLog(@"etcontent mouseup");
//    [[NSNotificationCenter defaultCenter] postNotificationName:@"ModTimersShouldReset" object:nil];
//    [super mouseUp:theEvent];
//}
//
//- (void)mouseDown:(NSEvent *)theEvent{
//    //    [[NSApp delegate] resetModTimers];
//    NSLog(@"etcontent mousedown");
//    [[NSNotificationCenter defaultCenter] postNotificationName:@"ModTimersShouldReset" object:nil];
//    [super mouseDown:theEvent];
//}

//- (void)keyDown:(NSEvent *)theEvent{
//  // NSLog(@"keydownCV");
////    [[NSApp delegate] resetModTimers];
//    [[NSNotificationCenter defaultCenter] postNotificationName:@"ModTimersShouldReset" object:nil];
//    [super keyDown:theEvent];
//   // [super interpretKeyEvents:[NSArray arrayWithObject:theEvent]];
//}

- (void)drawRect:(NSRect)dirtyRect
{
    [super drawRect:dirtyRect];
    if (!backColor) {
        backColor = [[[NSApp delegate] backgrndColor] retain];
    }
    [backColor set];
    NSRectFill([self bounds]);
    
}

- (void)setBackgroundColor:(NSColor *)inCol{
    if (backColor) {
        [backColor release];
    }
    backColor = inCol;
    [backColor retain];
}

- (NSColor *)backgroundColor{    
    if (!backColor) {
        backColor = [[[NSApp delegate] backgrndColor] retain];
    }
    return backColor;
}

@end
