
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


#import "DeletionManager.h"
#import "NoteObject.h"
#import "NotationController.h"
#import "NotationDirectoryManager.h"
#import "NotationPrefs.h"
#import "NSCollection_utils.h"

//class for managing notifications of external deletion of note files

@implementation DeletionManager

- (id)init {
	if ([super init]) {
		deletedNotes = [[NSMutableArray alloc] init];
	}
	return self;
}

- (id)initWithNotationController:(NotationController*)aNotationController {
	if ([self init]) {
		notationController = [aNotationController retain];
	}
	return self;
}

- (void)awakeFromNib {
	//[window setMaxSize:NSMakeSize(371, 0)];
	
	NSAssert(notationController != nil, @"attempting to awake DeletionManager without a NotationController");	
	
	[window setFloatingPanel:YES];
	[window setDelegate:self];
}

- (void)dealloc {

	[notationController release];
	notationController = nil;
	[deletedNotes release];
	[super dealloc];
}

- (NotationController*)notationController {
	return notationController;
}

- (BOOL)noteFileIsAlreadyDeleted:(NoteObject*)aNote {
	unsigned count = [deletedNotes count];
	if (count > 0) {
		
		unsigned int i;
		for (i=0; i<count; i++) {
			NoteObject *curNote = [deletedNotes objectAtIndex:i];
			if (compareFilename(&curNote, &aNote) == kCFCompareEqualTo) {
				return YES;
			}
		}
	}
	return NO;
}

- (void)addDeletedNotes:(NSArray*)array {
	if ([array count] > 0) {
		if (![deletedNotes count]) {
			//canceling the delayed selector would not be necessary if updateForVerifiedExistingNote 
			//did not have the potential to clear out deletedNotes before the selector posted to the next run loop
			[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(processDeletedNotes) object:nil];
			[self performSelector:@selector(processDeletedNotes) withObject:nil afterDelay:0];
		}
		
		BOOL didAddDeletedNote = NO;
		unsigned int i;
		for (i=0; i<[array count]; i++) {
			NoteObject *aNote = [array objectAtIndex:i];
			if (![self noteFileIsAlreadyDeleted:aNote]) {
				[deletedNotes addObject:aNote];
				didAddDeletedNote = YES;
			}
		}
		
		[array makeObjectsPerformSelector:@selector(invalidateFSRef)];
		
		if (didAddDeletedNote) {
			[self _updatePanelForNotes];
		}
	}
	hasDeletedNotes = [deletedNotes count] != 0;
}

- (void)addDeletedNote:(NoteObject*)aNote {
	
	if (aNote) {
		if (![deletedNotes count]) {
			[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(processDeletedNotes) object:nil];
			[self performSelector:@selector(processDeletedNotes) withObject:nil afterDelay:0];
		}
		//filter dups or remove these notes from allNotes before adding them here!
		if (![self noteFileIsAlreadyDeleted:aNote]) {
			[deletedNotes addObject:aNote];
			[self _updatePanelForNotes];
		}
		
		//clear fsref to ensure that files are re-created if they are restored
		//if they are to be deleted, we don't care about them, anyway--they should already be gone
		[aNote invalidateFSRef];
	}
	hasDeletedNotes = [deletedNotes count] != 0;
}

- (void)_updatePanelForNotes {
	[tableView reloadData];
	[window setFrame:[self windowSizeForNotesFromSender:window] display:NO];
}

void updateForVerifiedDeletedNote(DeletionManager *self, NoteObject *missingNote) {
	//called from [NotationController removeNote:]
	
	//just to underscore that this is really the same type of operation, call through to the other method
	updateForVerifiedExistingNote(self, missingNote);
}

void updateForVerifiedExistingNote(DeletionManager *self, NoteObject *goodNote) {
	//if there are deleted notes currently being shown and goodNote is among them, then update the dialog appropriately, dismissing it if necessary
	
	if (!self->hasDeletedNotes) return;
	
	NSUInteger priorNoteCount = [self->deletedNotes count];
	[self->deletedNotes removeObjectIdenticalTo:goodNote];
	NSUInteger latterNoteCount = [self->deletedNotes count];
	
	self->hasDeletedNotes = latterNoteCount != 0;
	
	if (latterNoteCount != priorNoteCount) {
		[self _updatePanelForNotes];
		if (!self->hasDeletedNotes) {
			[self cancelPanelReturningCode:1];
		}
	}
}


- (void)processDeletedNotes {
	
	if ([[notationController notationPrefs] confirmFileDeletion]) {
		[self showPanelForDeletedNotes];
	} else {
		[self removeDeletedNotes];
	}
}

- (NSRect)windowSizeForNotesFromSender:(id)sender {
	float oldHeight = 0.0;
	float newHeight = 0.0;
	NSRect newFrame = [sender frame];
	NSSize intercellSpacing = [tableView intercellSpacing];
	
	int numRows = MIN(20, [tableView numberOfRows]);
	newHeight = MAX(2, numRows) * ([tableView rowHeight] + intercellSpacing.height);	
	oldHeight = [[[tableView enclosingScrollView] contentView] frame].size.height;
	newHeight = [sender frame].size.height - oldHeight + newHeight;
	
	newFrame.origin.y = newFrame.origin.y + newFrame.size.height - newHeight;
	
	newFrame.size.height = newHeight;
	return newFrame;
}

- (void)showPanelForDeletedNotes {
	
	if (![deletedNotes count]) {
		NSLog(@"showPanelForDeletedNotes was asked to display without deleted notes");
		return;
	}
	
	if (!window) {
		if (![NSBundle loadNibNamed:@"DeletionManager" owner:self])  {
			NSLog(@"Failed to load DeletionManager.nib");
			NSBeep();
			return;
		}
	}
	[confirmDeletionButton setState:![[notationController notationPrefs] confirmFileDeletion]];
	
	//sort notes by title
	[deletedNotes sortUnstableUsingFunction:compareTitleString];
	
	[window setFrame:[self windowSizeForNotesFromSender:window] display:NO];
	
	if (![window isVisible])
		[window center];
	[window makeKeyAndOrderFront:nil];
	
	[NSApp cancelUserAttentionRequest:0];
}

- (void)removeDeletedNotes {
	
	//for purposes of generating useful undo messages
	if ([deletedNotes count] > 1) {
	
		[notationController removeNotes:[[deletedNotes copy] autorelease]];
		
	} else if ([deletedNotes count] == 1) {
		
		[notationController removeNote:[deletedNotes lastObject]];
		
	} else {
		NSLog(@"No deleted notes?!");
	}
}

- (void)cancelPanelReturningCode:(NSInteger)code {
	[window close];
}

- (IBAction)changeConfirmDeletion:(id)sender {
	[[notationController notationPrefs] setConfirmsFileDeletion:![confirmDeletionButton state]];
	[[NSNotificationCenter defaultCenter] postNotificationName:NotationPrefsDidChangeNotification object:nil];
}

- (IBAction)deleteAction:(id)sender {
	
	[self removeDeletedNotes];
}

- (IBAction)restoreAction:(id)sender {

	//force-write the files
	unsigned int i;
	for (i=0; i<[deletedNotes count]; i++) {
		[[deletedNotes objectAtIndex:i] makeNoteDirtyUpdateTime:NO updateFile:YES];
	}
	[notationController synchronizeNoteChanges:nil];
	
	//force-synchronize directory to get notationcontroller to tell DeletionManager that the file now exists via updateForVerifiedExistingNote
	//if restoring the file did not result in the dialog being dismissed, then it was not actually restored
	[NSObject cancelPreviousPerformRequestsWithTarget:notationController selector:@selector(synchronizeNotesFromDirectory) object:nil];
	[notationController synchronizeNotesFromDirectory];
}


- (BOOL)tableView:(NSTableView *)aTableView shouldEditTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	return NO;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex {
	return NO;
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	return filenameOfNote((NoteObject *)[deletedNotes objectAtIndex:rowIndex]);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
    return [deletedNotes count];
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)sender defaultFrame:(NSRect)defaultFrame {
	return [self windowSizeForNotesFromSender:sender];
}


@end
