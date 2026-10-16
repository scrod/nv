/* NVStrandedKeyResponder */

/*Copyright (c) 2026, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */

#import "NVStrandedKeyResponder.h"
#import "NotesTableView.h"

@implementation NVStrandedKeyResponder

- (instancetype)initWithNotesTableView:(NotesTableView*)aTable {
	if ((self = [super init])) {
		notesTable = aTable;
	}
	return self;
}

- (void)installAsTailOfResponderChainForWindow:(NSWindow*)aWindow {
	if ([aWindow nextResponder] == self)
		return;

	[self setNextResponder:[aWindow nextResponder]];
	[aWindow setNextResponder:self];
}

- (void)keyDown:(NSEvent*)theEvent {
	NSWindow *win = [notesTable window];

	/* the guard keeps a single pass through the note list, which bubbles events
	   it leaves to the responder chain and can route them back here */
	if (!isRedirectingKeyEvent && [win makeFirstResponder:notesTable]) {
		isRedirectingKeyEvent = YES;
		[notesTable keyDown:theEvent];
		isRedirectingKeyEvent = NO;
		return;
	}

	[super keyDown:theEvent];
}

@end
