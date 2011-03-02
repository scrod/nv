/* DeletionManager */

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
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

@class NotationController;
@class NoteObject;

@interface DeletionManager : NSObject
{
    IBOutlet NSTableView *tableView;
    IBOutlet NSPanel *window;
	IBOutlet NSButton *confirmDeletionButton;
	NSMutableArray *deletedNotes;
	NotationController* notationController;
	BOOL hasDeletedNotes;
}

- (id)initWithNotationController:(NotationController*)aNotationController;
- (NotationController*)notationController;
- (IBAction)changeConfirmDeletion:(id)sender;
- (BOOL)noteFileIsAlreadyDeleted:(NoteObject*)aNote;
- (void)addDeletedNotes:(NSArray*)array;
- (void)addDeletedNote:(NoteObject*)aNote;
- (NSRect)windowSizeForNotesFromSender:(id)sender;
void updateForVerifiedDeletedNote(DeletionManager *self, NoteObject *missingNote);
void updateForVerifiedExistingNote(DeletionManager *self, NoteObject *goodNote);
- (void)processDeletedNotes;
- (void)removeDeletedNotes;
- (void)_updatePanelForNotes;
- (void)showPanelForDeletedNotes;
- (void)cancelPanelReturningCode:(NSInteger)code;
- (IBAction)deleteAction:(id)sender;
- (IBAction)restoreAction:(id)sender;
@end
