#import "BookmarksTable.h"
#import "BookmarksController.h"
#import "NSString_NV.h"

@implementation BookmarksTable

- (id)initWithCoder:(NSCoder *)decoder {
	if ((self = [super initWithCoder:decoder])) {
	}
	return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent {
	return YES;
}

- (void)keyDown:(NSEvent*)theEvent {
	
	unichar keyChar = [theEvent firstCharacter];
	
    if (keyChar == NSDeleteCharacter || keyChar == NSDeleteFunctionKey) {
		[(BookmarksController*)[self dataSource] removeBookmark:nil];
		return;
	}
	
	[super keyDown:theEvent];
}
	

//force column re-layout while resizing
- (void)drawRect:(NSRect)aRect {
	
	[super drawRect:aRect];
}

@end
