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
