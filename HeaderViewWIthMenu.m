/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import "HeaderViewWIthMenu.h"
#import "NoteAttributeColumn.h"

@implementation HeaderViewWithMenu

- (id)init {
	if ([super init]) {
		isReloading = NO;
	}
	return self;
}

- (void)_resizeColumn:(NSInteger)resizedColIdx withEvent:(id)event {	
	//use a more understandable column resizing by changing the resizing mask immediately before calling through to the private method,
	//and reverting it back to the original at the next runloop iteration
	NSUInteger originalResizingMask = 0;
	int i;
	//change all user-resizable-only columns
	for (i=0; i<[[self tableView] numberOfColumns]; i++) {
		NoteAttributeColumn *col = [[[self tableView] tableColumns] objectAtIndex:i];
		if ((originalResizingMask = [col resizingMask]) == NSTableColumnUserResizingMask) {
			[col setResizingMask: NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask];
			[col performSelector:@selector(setResizingMaskNumber:) withObject:[NSNumber numberWithUnsignedInt:originalResizingMask] afterDelay:0];
		}
	}
	
	[super _resizeColumn:resizedColIdx withEvent:event];
}
	
- (void)setIsReloading:(BOOL)reloading {
	isReloading = reloading;
}

- (void)resetCursorRects {
	if (!isReloading) {
		[super resetCursorRects];
	}
}

- (NSMenu *)menuForEvent:(NSEvent *)theEvent {
    
    if ([[self tableView] respondsToSelector:@selector(menuForColumnConfiguration:)]) {
	NSPoint theClickPoint = [self convertPoint:[theEvent locationInWindow] fromView:NULL];
	int theColumn = [self columnAtPoint:theClickPoint];
	NSTableColumn *theTableColumn = nil;
	if (theColumn > -1)
	    theTableColumn = [[[self tableView] tableColumns] objectAtIndex:theColumn];
	
	NSMenu *theMenu = [[self tableView] performSelector:@selector(menuForColumnConfiguration:) withObject:theTableColumn];
	return theMenu;
    }
    
    return nil;
}


@end
