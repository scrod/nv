//
//  BookmarksController.h
//  Notation
//
//  Created by Zachary Schneirov on 1/21/07.
//  Copyright 2007 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class NoteObject;

@interface NoteBookmark : NSObject {
	NSString *searchString;
	CFUUIDBytes uuidBytes;
	NoteObject *noteObject;

	id delegate;
}

- (id)initWithDictionary:(NSDictionary*)aDict;
- (id)initWithNoteObject:(NoteObject*)aNote searchString:(NSString*)aString;
- (id)initWithNoteUUIDBytes:(CFUUIDBytes)bytes searchString:(NSString*)aString;

- (NSString*)searchString;
- (NoteObject*)noteObject;
- (void)validateNoteObject;
- (NSDictionary*)dictionaryRep;
- (void)setDelegate:(id)aDelegate;
- (id)delegate;

@end

/*
 menu is as follows
 
 Add to Saved Searches (filters duplicates)
 Remove from Saved Searches (enabled as necessary)
 Clear All Saved Searches
 --------
 search string A cmd-1
 search string B cmd-2
 search string C cmd-3
 ...
 search string J cmd-shift-1
 
 
 each item stores both the filter and the last selected note for that filter
 where the last selected note is updated whenever the filter is currently "in-play"
 */

@class GlobalPrefs;

@interface BookmarksController : NSObject {
	//model
	NSMutableArray *bookmarks;
		
	//for NoteObject <-> UUID lookups
	NSArray *notes;
	
	//for notifications
	id delegate, revealDelegate;
	BOOL isRestoringSearch, isSelectingProgrammatically;
	
	GlobalPrefs *prefsController;
	
	IBOutlet NSButton *addBookmarkButton;
    IBOutlet NSButton *removeBookmarkButton;
    IBOutlet NSTableView *bookmarksTableView;
    IBOutlet NSPanel *window;
	
	NSMenuItem *showHideBookmarksItem;
	
	NoteBookmark *currentBookmark;
}

- (id)initWithBookmarks:(NSArray*)array;
- (NSArray*)dictionaryReps;

- (void)setNotes:(NSArray*)someNotes;
- (NoteObject*)noteWithUUIDBytes:(CFUUIDBytes)bytes;
- (void)removeBookmarkForNote:(NoteObject*)aNote;

- (void)selectBookmarkInTableView:(NoteBookmark*)bookmark;

- (BOOL)restoreNoteBookmark:(NoteBookmark*)bookmark inBackground:(BOOL)inBG;

- (void)restoreBookmark:(id)sender;
- (void)clearAllBookmarks:(id)sender;
- (void)hideBookmarks:(id)sender;
- (void)showBookmarks:(id)sender;

- (void)restoreWindowFromSave;
- (void)loadWindowIfNecessary;

- (void)addBookmark:(id)sender;
- (void)removeBookmark:(id)sender;

- (void)regenerateBookmarksMenu;

- (BOOL)isVisible;

- (void)updateBookmarksUI;
- (void)setRevealDelegate:(id)aDelegate;
- (id)delegate;
- (void)setDelegate:(id)aDelegate;

@end

@interface NSObject (BookmarksControllerRevealDelegate)

- (void)bookmarksController:(BookmarksController*)controller restoreNoteBookmark:(NoteBookmark*)aBookmark inBackground:(BOOL)inBG;

@end
