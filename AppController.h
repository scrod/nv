/* AppController */

#import <Cocoa/Cocoa.h>

#import "NotationController.h"
#import "NotesTableView.h"

@class LinkingEditor;
@class EmptyView;
@class NotesTableView;
@class GlobalPrefs;
@class PrefsWindowController;
@class DualField;
@class RBSplitView;
@class RBSplitSubview;

@interface AppController : NSObject {
    IBOutlet DualField *field;
	IBOutlet RBSplitSubview *splitSubview;
	IBOutlet RBSplitView *splitView;
    IBOutlet NotesTableView *notesTableView;
    IBOutlet LinkingEditor *textView;
	IBOutlet EmptyView *editorStatusView;
	IBOutlet NSMenuItem *sparkleUpdateItem;
    IBOutlet NSWindow *window;
	
	NSMutableArray *notesToOpenOnLaunch;
	
    NSUndoManager *windowUndoManager;
    PrefsWindowController *prefsWindowController;
    GlobalPrefs *prefsController;
    NotationController *notationController;
	
	ViewLocationContext listUpdateViewCtx;
	BOOL isFilteringFromTyping, typedStringIsCached;
	BOOL isCreatingANote;
	NSString *typedString;
	
	NoteObject *currentNote;
	NSArray *savedSelectedNotes;
}

void outletObjectAwoke(id sender);

- (void)setNotationController:(NotationController*)newNotation;

- (void)setupViewsAfterAppAwakened;
- (void)runDelayedIUActionsAfterLaunch;
- (void)updateNoteMenus;

- (BOOL)addNotesFromPasteboard:(NSPasteboard*)pasteboard;
- (IBAction)renameNote:(id)sender;
- (IBAction)deleteNote:(id)sender;
- (IBAction)exportNote:(id)sender;
- (IBAction)printNote:(id)sender;
- (IBAction)tagNote:(id)sender;
- (IBAction)importNotes:(id)sender;

- (IBAction)fieldAction:(id)sender;
- (NoteObject*)createNoteIfNecessary;
- (BOOL)displayContentsForNoteAtIndex:(int)noteIndex;
- (void)processChangedSelectionForTable:(NSTableView*)table;
- (void)setEmptyViewState:(BOOL)state;
- (void)_setCurrentNote:(NoteObject*)aNote;
- (NoteObject*)selectedNoteObject;

- (void)setTableAllowsMultipleSelection;

- (NSString*)fieldSearchString;
- (void)cacheTypedStringIfNecessary:(NSString*)aString;
- (NSString*)typedString;

- (IBAction)showPreferencesWindow:(id)sender;
- (IBAction)bringFocusToControlField:(id)sender;
- (NSWindow*)window;

@end
