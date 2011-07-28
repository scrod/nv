//
//  StatusItemView.m
//  Notation
//
//  Created by elasticthreads on 07/03/2010.
//  Copyright 2010 elasticthreads. All rights reserved.
//

#import "StatusItemView.h"
#import "AppController.h"

NSString *imageName = @"nvMenuDark";

@implementation StatusItemView


- (id)initWithFrame:(NSRect)frame controller:(AppController *)ctrlr
{
    if (self == [super initWithFrame:frame]) {
        controller = ctrlr; // deliberately weak reference.
    }    
    return self;
}


- (void)dealloc
{
    controller = nil;
    [super dealloc];
}

- (void)drawRect:(NSRect)rect {
	if (clicked) {
        imageName=@"nvMenuC";
        [[NSColor selectedMenuItemColor] set];
		NSRectFill(rect);
    }else {
        if ([NSApp isActive]) {
            imageName = @"nvMenuDark";
        }else{
        imageName = @"nvMenuDark";
        }
		[[NSColor clearColor] set];
        NSRectFill(rect);
	}
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	NSString *path = [bundle pathForResource:imageName ofType:@"png"];
	NSImage *menuIcon = [[NSImage alloc] initWithContentsOfFile:path];
	NSSize msgSize = [menuIcon size];
    NSRect msgRect = NSMakeRect(0, 0, msgSize.width, msgSize.height);
    msgRect.origin.x = ([self frame].size.width - msgSize.width)/2;
    msgRect.origin.y = ([self frame].size.height - msgSize.height)/2;
	[menuIcon drawInRect:msgRect fromRect:NSZeroRect operation: NSCompositeSourceOver fraction:1.0];
	[menuIcon autorelease];
}

- (void)mouseDown:(NSEvent *)event
{
	clicked = YES;
	[self setNeedsDisplay:YES];
	BOOL doesit = [controller toggleAttachedWindow:self];
	if (doesit) {
		clicked = NO;
		[self setNeedsDisplay:YES];
	}	
}

- (void)mouseUp:(NSEvent *)event {
	clicked = NO;	
	[self setNeedsDisplay:YES];
	[self viewWillDraw];
}

- (void)rightMouseDown:(NSEvent *)event {
	clicked = YES;
	[self setNeedsDisplay:YES];
	BOOL doesit = [controller toggleAttachedMenu:self];
	if (doesit) {		
		clicked = NO;
		[self setNeedsDisplay:YES];
	}
}

- (void)setInactiveIcon:(id)sender{
	imageName = @"nvMenuDark";
	[self setNeedsDisplay:YES];
}

- (void)setActiveIcon:(id)sender{
    imageName=@"nvMenuDark";;
	[self setNeedsDisplay:YES];
}

@end
