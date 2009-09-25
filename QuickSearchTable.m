#import "QuickSearchTable.h"
#import "SavedSearchesController.h"

@implementation QuickSearchTable

- (id)initWithCoder:(NSCoder *)decoder {
	if (self = [super initWithCoder:decoder]) {
	}
	return self;
}

- (void)editColumn:(int)columnIndex row:(int)rowIndex withEvent:(NSEvent *)theEvent select:(BOOL)flag {
	
	[super editColumn:columnIndex row:rowIndex withEvent:theEvent select:flag];
	
	//this is way easier and faster than a custom formatter! just change the title while we're editing!
	SavedSearch *search = [(SavedSearchesController*)[self dataSource] savedSearchAtIndex:rowIndex];
	if (search) {
		NSTextView *editor = (NSTextView*)[self currentEditor];
		[editor setString:[search searchString]];
		[editor setSelectedRange:NSMakeRange(0, [[search searchString] length])];
	}
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent {
	return YES;
}

- (void)keyDown:(NSEvent*)theEvent {
	
	unichar keyChar = [[theEvent characters] characterAtIndex:0];
	
    if (keyChar == NSNewlineCharacter || keyChar == NSCarriageReturnCharacter || keyChar == NSEnterCharacter) {
		unsigned int sel = [self selectedRow];
		if (sel < [self numberOfRows] && [self numberOfSelectedRows] == 1) {
			[self editColumn:0 row:sel withEvent:theEvent select:YES];
			return;
		}
    } else if (keyChar == NSDeleteCharacter || keyChar == NSDeleteFunctionKey) {
		[(SavedSearchesController*)[self dataSource] removeSearch:nil];
		return;
	}
	
	[super keyDown:theEvent];
}
	

//force column re-layout while resizing
- (void)drawRect:(NSRect)aRect {
	
	[super drawRect:aRect];
}

@end
