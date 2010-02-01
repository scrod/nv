/* DeletionManager */

#import <Cocoa/Cocoa.h>

@class NoteObject;

@interface DeletionManager : NSObject
{
    IBOutlet NSTableView *tableView;
    IBOutlet NSPanel *window;
	NSWindow *mainWindow;
	NSMutableArray *deletedNotes;
	id delegate;
	
	BOOL needsToShowSheet;
}

+ (DeletionManager *)sharedManager;
- (void)setDelegate:(id)aDelegate;
- (id)delegate;
- (BOOL)noteFileIsAlreadyDeleted:(NoteObject*)aNote;
- (void)addDeletedNotes:(NSArray*)array;
- (void)addDeletedNote:(NoteObject*)aNote;
- (void)processDeletedNotes;
- (void)removeDeletedNotes;
- (NSRect)windowSizeForNotes;
- (void)_updateSheetForNotes;
- (void)showSheetForDeletedNotes;
- (IBAction)deleteAction:(id)sender;
- (IBAction)restoreAction:(id)sender;
@end
