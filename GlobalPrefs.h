//
//  GlobalPrefs.h
//  Notation
//
//  Created by Zachary Schneirov on 1/31/06.

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
#import "SynchronizedNoteProtocol.h"

extern NSString *NoteTitleColumnString;
extern NSString *NoteLabelsColumnString;
extern NSString *NoteDateModifiedColumnString;
extern NSString *NoteDateCreatedColumnString;
extern NSString *NotePreviewString;

extern NSString *NVPTFPboardType;

@class NotesTableView;
@class BookmarksController;
@class NotationPrefs;
@class PTKeyCombo;
@class PTHotKey;

@interface GlobalPrefs : NSObject {
	NSUserDefaults *defaults;
	
	IMP runCallbacksIMP;
	NSMutableDictionary *selectorObservers;
	
	PTKeyCombo *appActivationKeyCombo;
	PTHotKey *appActivationHotKey;
	
	BookmarksController *bookmarksController;
	NotationPrefs *notationPrefs;
	NSDictionary *noteBodyAttributes, *searchTermHighlightAttributes;
	NSMutableParagraphStyle *noteBodyParagraphStyle;
	NSFont *noteBodyFont;
	NSColor *searchTermHighlightColor;
	BOOL autoCompleteSearches;
	
	NSMutableArray *tableColumns;
}

+ (GlobalPrefs *)defaultPrefs;

- (void)registerWithTarget:(id)sender forChangesInSettings:(SEL)firstSEL, ...;
- (void)registerForSettingChange:(SEL)selector withTarget:(id)sender;
- (void)unregisterForNotificationsFromSelector:(SEL)selector sender:(id)sender;
- (void)notifyCallbacksForSelector:(SEL)selector excludingSender:(id)sender;

- (void)setNotationPrefs:(NotationPrefs*)newNotationPrefs sender:(id)sender;
- (NotationPrefs*)notationPrefs;

- (void)removeTableColumn:(NSString*)columnKey sender:(id)sender;
- (void)addTableColumn:(NSString*)columnKey sender:(id)sender;
- (NSArray*)visibleTableColumns;

- (void)setSortedTableColumnKey:(NSString*)sortedKey reversed:(BOOL)reversed sender:(id)sender;
- (NSString*)sortedTableColumnKey;
- (BOOL)tableIsReverseSorted;

- (BOOL)tableColumnsShowPreview;
- (void)setTableColumnsShowPreview:(BOOL)showPreview sender:(id)sender;

- (void)resolveNoteBodyFontFromNotationPrefsFromSender:(id)sender;
- (void)_setNoteBodyFont:(NSFont*)aFont;
- (void)setNoteBodyFont:(NSFont*)aFont sender:(id)sender;
- (NSFont*)noteBodyFont;
- (NSDictionary*)noteBodyAttributes;
- (NSParagraphStyle*)noteBodyParagraphStyle;
- (BOOL)_bodyFontIsMonospace;

- (void)setTabIndenting:(BOOL)value sender:(id)sender;
- (BOOL)tabKeyIndents;

- (void)setUseTextReplacement:(BOOL)value sender:(id)sender;
- (BOOL)useTextReplacement;	

- (void)setCheckSpellingAsYouType:(BOOL)value sender:(id)sender;
- (BOOL)checkSpellingAsYouType;

- (void)setConfirmNoteDeletion:(BOOL)value sender:(id)sender;
- (BOOL)confirmNoteDeletion;

- (void)setQuitWhenClosingWindow:(BOOL)value sender:(id)sender;
- (BOOL)quitWhenClosingWindow;

- (void)setAppActivationKeyCombo:(PTKeyCombo*)aCombo sender:(id)sender;
- (PTKeyCombo*)appActivationKeyCombo;
- (PTHotKey*)appActivationHotKey;
- (BOOL)registerAppActivationKeystrokeWithTarget:(id)target selector:(SEL)selector;

- (void)setPastePreservesStyle:(BOOL)value sender:(id)sender;
- (BOOL)pastePreservesStyle;

- (void)setLinksAutoSuggested:(BOOL)value sender:(id)sender;
- (BOOL)linksAutoSuggested;

- (void)setMakeURLsClickable:(BOOL)value sender:(id)sender;
- (BOOL)URLsAreClickable;

- (void)setSearchTermHighlightColor:(NSColor*)color sender:(id)sender;
- (NSDictionary*)searchTermHighlightAttributes;
- (NSColor*)searchTermHighlightColor;

- (void)setSoftTabs:(BOOL)value sender:(id)sender;
- (BOOL)softTabs;

- (int)numberOfSpacesInTab;

- (BOOL)drawFocusRing;

- (float)tableFontSize;
- (void)setTableFontSize:(float)fontSize sender:(id)sender;

- (BOOL)autoCompleteSearches;
- (void)setAutoCompleteSearches:(BOOL)value sender:(id)sender;

- (NSString*)lastSelectedPreferencesPane;
- (void)setLastSelectedPreferencesPane:(NSString*)pane sender:(id)sender;

- (double)scrollOffsetOfLastSelectedNote;
- (CFUUIDBytes)UUIDBytesOfLastSelectedNote;
- (NSString*)lastSearchString;
- (void)setLastSearchString:(NSString*)string selectedNote:(id<SynchronizedNote>)aNote scrollOffsetForTableView:(NotesTableView*)tv sender:(id)sender;

- (void)saveCurrentBookmarksFromSender:(id)sender;
- (BookmarksController*)bookmarksController;

- (void)setAliasDataForDefaultDirectory:(NSData*)alias sender:(id)sender;
- (NSData*)aliasDataForDefaultDirectory;

- (NSImage*)iconForDefaultDirectoryWithFSRef:(FSRef*)fsRef;
- (NSString*)displayNameForDefaultDirectoryWithFSRef:(FSRef*)fsRef;
- (NSString*)humanViewablePathForDefaultDirectory;

- (void)setBlorImportAttempted:(BOOL)value;
- (BOOL)triedToImportBlor;

- (void)synchronize;

@end

@interface NSObject (GlobalPrefsDelegate)
	- (void)settingChangedForSelectorString:(NSString*)selectorString;
@end


