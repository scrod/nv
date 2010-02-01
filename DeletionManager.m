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

- (void)awakeFromNib {
	//[window setMaxSize:NSMakeSize(371, 0)];
	
	mainWindow = [[NSApp delegate] window];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidEndSheet:) 
												 name:NSWindowDidEndSheetNotification object:mainWindow];	
}

+ (DeletionManager *)sharedManager {
	static DeletionManager *man = nil;
	if (!man)
		man = [[DeletionManager alloc] init];
	return man;
}

- (void)dealloc {

	[deletedNotes release];
	[super dealloc];
}

- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}
- (id)delegate {
	return delegate;
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
		
		unsigned int i;
		for (i=0; i<[array count]; i++) {
			NoteObject *aNote = [array objectAtIndex:i];
			if (![self noteFileIsAlreadyDeleted:aNote])
				[deletedNotes addObject:aNote];
		}
		
		[array makeObjectsPerformSelector:@selector(invalidateFSRef)];
		
		[self _updateSheetForNotes];
	}
}

- (void)addDeletedNote:(NoteObject*)aNote {
	
	if (aNote) {
		if (![deletedNotes count]) {
			[self performSelector:@selector(processDeletedNotes) withObject:nil afterDelay:0];
		}
		//filter dups or remove these notes from allNotes before adding them here!
		if (![self noteFileIsAlreadyDeleted:aNote])
			[deletedNotes addObject:aNote];
		
		//clear fsref to ensure that files are re-created if they are restored
		//if they are to be deleted, we don't care about them, anyway--they should already be gone
		[aNote invalidateFSRef];
		
		[self _updateSheetForNotes];
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
	
		if ([delegate respondsToSelector:@selector(removeNotes:)])
			[delegate removeNotes:deletedNotes];
		
	} else if ([deletedNotes count] == 1) {
		
		if ([delegate respondsToSelector:@selector(removeNote:)])
			[delegate removeNote:[deletedNotes lastObject]];
		
	} else {
		NSLog(@"No deleted notes?!");
	}
	
	[deletedNotes removeAllObjects];
}


- (IBAction)deleteAction:(id)sender {
	
	[self removeDeletedNotes];
	
	[NSApp endSheet:window returnCode:1];
	[window close];
}

- (IBAction)restoreAction:(id)sender {

	unsigned int i;
	for (i=0; i<[deletedNotes count]; i++) {
		[[deletedNotes objectAtIndex:i] makeNoteDirtyUpdateTime:NO updateFile:YES];
	}
	[delegate synchronizeNoteChanges:nil];
	
	//cancel any file synchronization that's about to run after the sheet to make sure that it doesn't catch files before rewriting
	[NSObject cancelPreviousPerformRequestsWithTarget:delegate selector:@selector(synchronizeNotesFromDirectory) object:nil];
	
	[deletedNotes removeAllObjects];
	
	[NSApp endSheet:window returnCode:0];
	[window close];
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
