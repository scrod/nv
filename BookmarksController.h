//
//  BookmarksController.h
//  Notation
//
//  Created by Zachary Schneirov on 1/21/07.

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

@class AppController;
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

@interface BookmarksController : NSObject 
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6
<NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource> 
#endif
{
	//model
	NSMutableArray *bookmarks;
		
	//for NoteObject <-> UUID lookups
	id dataSource;
	
	//for notifications
	AppController *appController;
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

- (id)dataSource;
- (void)setDataSource:(id)aDataSource;
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

- (AppController*)appController;
- (void)setAppController:(id)aDelegate;

@end

@interface NSObject (BookmarksControllerRevealDelegate)

- (void)bookmarksController:(BookmarksController*)controller restoreNoteBookmark:(NoteBookmark*)aBookmark inBackground:(BOOL)inBG;

@end

@interface NSObject (BookmarksControllerDataSource)

- (NoteObject*)noteForUUIDBytes:(CFUUIDBytes*)bytes;

@end

