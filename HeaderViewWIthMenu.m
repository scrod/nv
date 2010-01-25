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
