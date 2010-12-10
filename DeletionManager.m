
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
#import "NotationPrefs.h"
#import "GlobalPrefs.h"
#import "NSCollection_utils.h"

//class for managing notifications of external deletion of note files

@implementation DeletionManager

- (id)init {
	if ([super init]) {
		deletedNotes = [[NSMutableArray alloc] init];
		
		needsToShowSheet = NO;
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
	
	mainWindow = [[notationController delegate] window];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidEndSheet:) 
												 name:NSWindowDidEndSheetNotification object:mainWindow];	
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
			[self _updateSheetForNotes];
		}
	}
}

- (void)addDeletedNote:(NoteObject*)aNote {
	
	if (aNote) {
		if (![deletedNotes count]) {
			[self performSelector:@selector(processDeletedNotes) withObject:nil afterDelay:0];
		}
		//filter dups or remove these notes from allNotes before adding them here!
		if (![self noteFileIsAlreadyDeleted:aNote]) {
			[deletedNotes addObject:aNote];
			[self _updateSheetForNotes];
		}
		
		//clear fsref to ensure that files are re-created if they are restored
		//if they are to be deleted, we don't care about them, anyway--they should already be gone
		[aNote invalidateFSRef];
	}
}

- (void)_updateSheetForNotes {
	[tableView reloadData];
	[window setFrame:[self windowSizeForNotes] display:[window isVisible] animate:[window isVisible]];
}


- (void)processDeletedNotes {
	
	if ([[[GlobalPrefs defaultPrefs] notationPrefs] confirmFileDeletion]) {
		[self showSheetForDeletedNotes];
	} else {
		[self removeDeletedNotes];
	}
}

- (NSRect)windowSizeForNotes {
	float oldHeight = 0.0;
	float newHeight = 0.0;
	NSRect newFrame = [window frame];
	NSSize intercellSpacing = [tableView intercellSpacing];
	
	int numRows = MIN(20, [tableView numberOfRows]);
	newHeight = MAX(2, numRows) * ([tableView rowHeight] + intercellSpacing.height);	
	oldHeight = [[[tableView enclosingScrollView] contentView] frame].size.height;
	newHeight = [window frame].size.height - oldHeight + newHeight;
	
	newFrame.origin.y = newFrame.origin.y + newFrame.size.height - newHeight;
	
	newFrame.size.height = newHeight;
	return newFrame;	
}

- (void)showSheetForDeletedNotes {
	
	if (!window) {
		if (![NSBundle loadNibNamed:@"DeletionManager" owner:self])  {
			NSLog(@"Failed to load DeletionManager.nib");
			NSBeep();
			return;
		}
	}	
	
	//sort notes by title
	[deletedNotes sortUnstableUsingFunction:compareTitleString];
	
	needsToShowSheet = YES;
	
	[window setFrame:[self windowSizeForNotes] display:NO];
	
	[NSApp beginSheet:window modalForWindow:mainWindow modalDelegate:self 
	   didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
	
	[NSApp cancelUserAttentionRequest:0];
	
	if ([mainWindow attachedSheet] == window)
		needsToShowSheet = NO;
}

- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	
}

- (void)removeDeletedNotes {
	
	//for purposes of generating useful undo messages
	if ([deletedNotes count] > 1) {
	
		[notationController removeNotes:deletedNotes];
		
	} else if ([deletedNotes count] == 1) {
		
		[notationController removeNote:[deletedNotes lastObject]];
		
	} else {
		NSLog(@"No deleted notes?!");
	}
	
	[deletedNotes removeAllObjects];
}

- (void)cancelPanelReturningCode:(NSInteger)code {
	if (window) {
		[NSApp endSheet:window returnCode:code];
		[window close];
	}
}

- (IBAction)deleteAction:(id)sender {
	
	[self removeDeletedNotes];
	
	[self cancelPanelReturningCode:1];
}

- (IBAction)restoreAction:(id)sender {

	unsigned int i;
	for (i=0; i<[deletedNotes count]; i++) {
		[[deletedNotes objectAtIndex:i] makeNoteDirtyUpdateTime:NO updateFile:YES];
	}
	[notationController synchronizeNoteChanges:nil];
	
	//cancel any file synchronization that's about to run after the sheet to make sure that it doesn't catch files before rewriting
	[NSObject cancelPreviousPerformRequestsWithTarget:notationController selector:@selector(synchronizeNotesFromDirectory) object:nil];
	
	[deletedNotes removeAllObjects];
	
	[self cancelPanelReturningCode:0];
}

- (void)windowDidEndSheet:(NSNotification *)aNotification {

	if (needsToShowSheet) {
		//we didn't show ourselves and we still need to--now's the time!
		NSLog(@"trying to show sheet again");
		[self showSheetForDeletedNotes];
	}
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

@end
