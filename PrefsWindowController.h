/* PrefsWindowController */

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
    IBOutlet NSButton *togDockButton;
	IBOutlet NSTextField *togDockLabel;
	IBOutlet NSSlider *maxWidthSlider;	
    IBOutlet NotationPrefsViewController *notationPrefsViewController;
	IBOutlet NSComboBox *appList;
    IBOutlet NSButton *useMarkdownImportButton;
	IBOutlet NSButton *useReadabilityButton;
    IBOutlet NSButton *showGridButton;
    IBOutlet NSButton *altRowsButton;
	NSMutableParagraphStyle *centerStyle;
	NSMutableDictionary *items;
	NSToolbar *toolbar;
	BOOL fontPanelWasOpen;
	
	IBOutlet NSWindow *window;
	IBOutlet NSView *editingView, *generalView, *fontsColorsView, *databaseView, *notationPrefsView;
	IBOutlet NSButton *rtlButton;
	IBOutlet NSButton *autoPairButton;
    
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
- (IBAction)changedRTL:(id)sender;
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
- (IBAction)changedUseMarkdownImport:(id)sender;
- (IBAction)changedUseReadability:(id)sender;
- (IBAction)changedShowGrid:(id)sender;
- (IBAction)changedAltRows:(id)sender;
- (IBAction)changedAutoPairing:(id)sender;

- (void)_selectDefaultExternalEditor;

- (NSMenu*)directorySelectionMenu;
- (void)changeDefaultDirectory;
- (BOOL)getNewNotesRefFromOpenPanel:(FSRef*)notesDirectoryRef returnedPath:(NSString**)path;

- (NotationPrefsViewController*)notationPrefsViewController;
- (NSView*)databaseView;
- (void)addToolbarItemWithName:(NSString*)name;
- (void)switchViews:(NSToolbarItem *)item;
	NSRect ScaleRectWithFactor(NSRect rect, float factor);
- (IBAction)toggleHideDockIcon:(id)sender;
- (IBAction)toggleKeepsTextWidthInWindow:(id)sender;
- (IBAction)setMaxWidth:(id)sender;
- (void)relaunchNV:(id)sender;
- (void)reActivate:(id)sender;

@end
