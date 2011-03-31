/* PrefsWindowController */

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

@class NotationPrefsViewController;
@class GlobalPrefs;

@interface PrefsWindowController : NSObject 
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6
<NSWindowDelegate, NSToolbarDelegate>
#endif
{
    IBOutlet NSPopUpButton *folderLocationsMenuButton;
    IBOutlet NSTextField *bodyTextFontField;
    IBOutlet NSMatrix *tabKeyRadioMatrix;
    IBOutlet NSPopUpButton *tableTextMenuButton;
	IBOutlet NSPopUpButton *externalEditorMenuButton;
    IBOutlet NSTextField *tableTextSizeField;
    IBOutlet NSTextField *appShortcutField;
	IBOutlet NSButton *completeNoteTitlesButton;
	IBOutlet NSButton *checkSpellingButton;
	IBOutlet NSButton *confirmDeletionButton;
	IBOutlet NSButton *quitWhenClosingButton;
	IBOutlet NSButton *styledTextButton;
	IBOutlet NSButton *autoSuggestLinksButton;
	IBOutlet NSButton *softTabsButton;
	IBOutlet NSButton *makeURLsClickable;
	IBOutlet NSButton *highlightSearchTermsButton;
	IBOutlet NSColorWell *searchHighlightColorWell, *foregroundColorWell, *backgroundColorWell;
    
    IBOutlet NotationPrefsViewController *notationPrefsViewController;
	
	NSMutableParagraphStyle *centerStyle;
	NSMutableDictionary *items;
	NSToolbar *toolbar;
	BOOL fontPanelWasOpen;
	
	IBOutlet NSWindow *window;
	IBOutlet NSView *editingView, *generalView, *fontsColorsView, *databaseView, *notationPrefsView;
	
	GlobalPrefs *prefsController;
}
- (void)showWindow:(id)sender;

- (IBAction)changedBackgroundTextColorWell:(id)sender;
- (IBAction)changedForegroundTextColorWell:(id)sender;
- (IBAction)changedHighlightSearchTerms:(id)sender;	
- (IBAction)changedSearchHighlightColorWell:(id)sender;
- (IBAction)changedMakeURLsClickable:(id)sender;
- (IBAction)changedStyledTextBehavior:(id)sender;
- (IBAction)changedAutoSuggestLinks:(id)sender;
- (IBAction)setAppShortcut:(id)sender;
- (IBAction)changeBodyFont:(id)sender;
- (void)previewNoteBodyFont;
- (IBAction)changedNoteDeletion:(id)sender;
- (IBAction)changedNotesFolderLocation:(id)sender;
- (IBAction)changedQuitBehavior:(id)sender;
- (IBAction)changedSpellChecking:(id)sender;
- (IBAction)changedTabBehavior:(id)sender;
- (IBAction)changedTableText:(id)sender;
- (IBAction)changedExternalEditorsMenu:(id)sender;
- (IBAction)changedTitleCompletion:(id)sender;
- (IBAction)changedSoftTabs:(id)sender;

- (void)_selectDefaultExternalEditor;

- (NSMenu*)directorySelectionMenu;
- (void)changeDefaultDirectory;
- (BOOL)getNewNotesRefFromOpenPanel:(FSRef*)notesDirectoryRef returnedPath:(NSString**)path;

- (NotationPrefsViewController*)notationPrefsViewController;
- (NSView*)databaseView;
- (void)addToolbarItemWithName:(NSString*)name;
- (void)switchViews:(NSToolbarItem *)item;
	NSRect ScaleRectWithFactor(NSRect rect, float factor);
@end
