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

#import <Cocoa/Cocoa.h>

@class NotesTableView;

/* Occupies the tail of the window's responder chain, which is where a key event
   arrives once the first responder and each of its superviews have had their turn.
   A titlebar or toolbar click leaves the window in that state: focus moves out of
   the note list and into the window itself (or into a titlebar view that passes
   key events along), so keystrokes travel the whole chain and reach here.

   Such a keystroke resumes in the note list, which applies its usual
   interpretation -- typing searches, arrows move the selection, Return renames,
   Delete deletes -- so focus lands where the keyboard-centric design expects it
   and NotesTableView remains the single description of that behavior. */

@interface NVStrandedKeyResponder : NSResponder {
	NotesTableView *notesTable; //non-retained; outlives this object
	BOOL isRedirectingKeyEvent;
}

- (instancetype)initWithNotesTableView:(NotesTableView*)aTable;

/* Appends the receiver after the window's existing next responder, keeping the
   place of any responder already installed there. */
- (void)installAsTailOfResponderChainForWindow:(NSWindow*)aWindow;

@end
