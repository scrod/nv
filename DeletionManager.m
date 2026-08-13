
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


#import "DeletionManager.h"
#import "NoteObject.h"
#import "NotationController.h"
#import "NotationDirectoryManager.h"
#import "NotationPrefs.h"
#import "NSCollection_utils.h"

//class for managing notifications of external deletion of note files

@implementation DeletionManager

@synthesize notationController;

- (id)init {
	self = [super init];
	if (self) {
		deletedNotes = [[NSMutableArray alloc] init];
	}
	return self;
}

- (id)initWithNotationController:(NotationController*)aNotationController {
	self = [self init];
	if (self) {
		notationController = aNotationController;
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

	notationController = nil;
	[deletedNotes release];
	[deletionManagerTopLevelObjects release];
	[super dealloc];
}

- (BOOL)noteFileIsAlreadyDeleted:(NoteObject*)aNote {
	if ([deletedNotes count] > 0) {
		for (NoteObject *curNote in deletedNotes) {
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
		for (NoteObject *aNote in array) {
			if (![self noteFileIsAlreadyDeleted:aNote]) {
				[deletedNotes addObject:aNote];
				didAddDeletedNote = YES;
			}
		}
		
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
		
	}
	hasDeletedNotes = [deletedNotes count] != 0;
}

- (void)reconcileVerifiedExistingNotes:(NSSet*)existingNotes deletedNotes:(NSArray*)missingNotes {
	/* A directory transaction publishes its complete decision once.  Updating the
	 * candidate array in one batch avoids transient panels and repeated table
	 * reloads while a successful scan is committing. */
	NSArray *oldNotes = [[deletedNotes copy] autorelease];
	for (NoteObject *note in existingNotes)
		[deletedNotes removeObjectIdenticalTo:note];
	for (NoteObject *note in missingNotes)
		if (![self noteFileIsAlreadyDeleted:note]) [deletedNotes addObject:note];
	hasDeletedNotes = [deletedNotes count] != 0;
	if (![deletedNotes isEqualToArray:oldNotes]) {
		[self _updatePanelForNotes];
		if (!hasDeletedNotes) [self cancelPanelReturningCode:1];
	}
	if (![oldNotes count] && [deletedNotes count]) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(processDeletedNotes) object:nil];
		[self performSelector:@selector(processDeletedNotes) withObject:nil afterDelay:0];
	}
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
	
    NSInteger numRows = MIN((NSInteger)20, [tableView numberOfRows]);
    newHeight = MAX((NSInteger)2, numRows) * ([tableView rowHeight] + intercellSpacing.height);
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
		NSArray *topLevelObjects = nil;
		if (![[NSBundle mainBundle] loadNibNamed:@"DeletionManager" owner:self topLevelObjects:&topLevelObjects])  {
			NSLog(@"Failed to load DeletionManager.nib");
			NSBeep();
			return;
		}
		[deletionManagerTopLevelObjects release];
		deletionManagerTopLevelObjects = [topLevelObjects retain];
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
	for (NoteObject *note in deletedNotes) {
		[note makeNoteDirtyUpdateTime:NO updateFile:YES];
	}
	[notationController synchronizeNoteChanges:nil];
	
	//force-synchronize directory to get notationcontroller to tell DeletionManager that the file now exists via updateForVerifiedExistingNote
	//if restoring the file did not result in the dialog being dismissed, then it was not actually restored
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
