/* DeletionManager */

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
