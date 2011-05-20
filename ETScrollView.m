//
//  ETScrollView.m
//  Notation
//
//  Created by elasticthreads on 3/14/11.
//

#import "ETScrollView.h"
#import "ETTransparentScroller.h"

@implementation ETScrollView

- (id)init
{
    self = [super init];
    if (self) {
        // Initialization code here.
    }
    
    return self;
}

- (void)dealloc
{
    [super dealloc];
}

- (NSView *)hitTest:(NSPoint)aPoint{
    if (NSPointInRect (aPoint,[[self verticalScroller] frame])) {
        return [self verticalScroller];
    }else{
        return [self documentView];
    }
}




- (void)awakeFromNib{
    if (!IsLionOrLater) {
      //  ETTransparentScroller *tScroll = [[[ETTransparentScroller alloc]init] retain];
        [self setVerticalScroller:[[ETTransparentScroller alloc]init]];
      //  [tScroll release];
    }
}
/*
- (void)drawRect:(NSRect)rect{
    [super drawRect:rect];
   // rect = [self frame];
    NSRect cornerRect = [[self verticalScroller] frame];
    cornerRect.size.height = cornerRect.size.width;
    cornerRect.origin.x = rect.origin.x + rect.size.width - cornerRect.size.width;
    cornerRect.origin.y += [[self verticalScroller] frame].size.height;
    cornerRect.origin.y -= 5;//cornerRect.size.height;
    
    [[NSColor redColor] setFill];
     NSRectFill(cornerRect);
    

}

 - (void)tile{
   [super tile];
    if ([self hasVerticalScroller]) {
        // NSLog(@"subviwes are: %@",[[self subviews] description]);
        //NSRect docRect = [self frame];
      //  docRect.size.width -=40;
        //[self setFrame:docRect];
       // NSRect docRect = [self frame];
       // NSRect clipRect = [[self contentView] frame];
        // NSRect scrollRect = [[self verticalScroller] frame];
        //NSRect bRect = [self frame];
        //bRect.size.width +=28;
      //  [self setFrame:bRect];
     //   cornerRect.size.height = cornerRect.size.width;
       // cornerRect.origin.x -=200;
       // cornerRect.origin.y +=200;
        //   clipRect.size.width -=280;
       // docRect.size.width +=15;
       // [self setFrame:docRect];
       // clipRect.size.width -=55;
        //[[self contentView] setFrame:clipRect];
        //scrollRect.origin.x +=15;
       // [[self verticalScroller]setFrame:scrollRect];
      //  [[self horizontalScroller]setFrame:cornerRect];
         //[[NSColor redColor] setFill];
        // NSRectFill(cornerRect);
    //[self setNeedsDisplay:YES];
     }
    //}
}*/


@end
