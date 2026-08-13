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


#import "AppController.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "AlienNoteImporter.h"
#import "AppController_Importing.h"
#import "NotationPrefs.h"
#import "PrefsWindowController.h"
#import "NoteAttributeColumn.h"
#import "NotationSyncServiceManager.h"
#import "NotationDirectoryManager.h"
#import "NotationFileManager.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "EncodingsManager.h"
#import "ExporterManager.h"
#import "ExternalEditorListController.h"
#import "ExternalEditingSession/ExternalEditingSession.h"
#import "NSData_transformations.h"
#import "BufferUtils.h"
#import "LinkingEditor.h"
#import "EmptyView.h"
#import "DualField.h"
#import "TitlebarButton.h"
#import "RBSplitView/RBSplitView.h"
#import <objc/message.h>

@interface SPUUpdater : NSObject
- (void)setAutomaticallyChecksForUpdates:(BOOL)flag;
@end
@interface SPUStandardUpdaterController : NSObject
- (IBAction)checkForUpdates:(nullable id)sender;
@end

// Forward-declare a private AppKit selector used in menu tweaking
@interface NSMenu (NVPrivate)
- (void)_removeLinkFromMenu:(id)sender;
@end

// Dummy declaration to silence undeclared-selector warning for @selector(noop:)
@interface NSObject (NVNoop)
- (void)noop:(id)sender;
@end

@interface AppController ()
@property (nonatomic, retain) TagEditingManager *tagEditor;
@property (nonatomic, retain) NSArray *savedSelectedNotes;
- (void)_loadNotationAtURL:(NSURL*)URL;
- (BOOL)_confirmEndingExternalEditingForAction:(NSString*)action
	continueButtonTitle:(NSString*)continueButtonTitle;
- (BOOL)_externalEditingQuitResponseShouldTerminate:(NSModalResponse)response;
- (void)_confirmQuittingExternalEditingWithCompletionHandler:
	(void (^)(BOOL shouldQuit))completionHandler;
- (void)_restoreWindowAfterCanceledTermination;
@end
#import "AugmentedScrollView.h"
#import "BookmarksController.h"
#import "SyncSessionController.h"
#import "MultiplePageView.h"
#import "InvocationRecorder.h"
#import "LinearDividerShader.h"
#import "SecureTextEntryManager.h"
#import "NSString_CustomTruncation.h"
#import "TagEditingManager.h"


@implementation AppController

@synthesize tagEditor, savedSelectedNotes;

//an instance of this class is designated in the nib as the delegate of the window, nstextfield and two nstextviews

- (id)init {
    self = [super init];
    if (self) {

		windowUndoManager = [[NSUndoManager alloc] init];

		// Setup URL Handling
		NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
		[appleEventManager setEventHandler:self andSelector:@selector(handleGetURLEvent:withReplyEvent:) forEventClass:kInternetEventClass andEventID:kAEGetURL];

		dividerShader = [[LinearDividerShader alloc] initWithStartColor:[NSColor colorWithWhite:0.988 alpha:1.0]
																   endColor:[NSColor colorWithWhite:0.875 alpha:1.0]
														 darkStartColor:[NSColor colorWithWhite:0.20 alpha:1.0]
														   darkEndColor:[NSColor colorWithWhite:0.12 alpha:1.0]];

		isCreatingANote = isFilteringFromTyping = typedStringIsCached = NO;
		typedString = @"";

    }
    return self;
}

- (void)awakeFromNib {
	prefsController = [GlobalPrefs defaultPrefs];

	[NSColor setIgnoresAlpha:NO];

	NSView *dualSV = [field superview];
	dualFieldItem = [[NSToolbarItem alloc] initWithItemIdentifier:@"DualField"];
	//[[dualSV superview] setFrameSize:NSMakeSize([[dualSV superview] frame].size.width, [[dualSV superview] frame].size.height -1)];
	[dualFieldItem setView:dualSV];

	// Create a static label toolbar item titled "Notation" to the left of the DualField
	appTitleItem = [[NSToolbarItem alloc] initWithItemIdentifier:@"AppTitleLabel"];
	{
		NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
		[titleLabel setBezeled:NO];
		[titleLabel setDrawsBackground:NO];
		[titleLabel setEditable:NO];
		[titleLabel setSelectable:NO];
		// Explicitly set bold font via attributed string to avoid toolbar overrides
		CGFloat fontSize = [NSFont systemFontSizeForControlSize:NSControlSizeRegular];
		NSFont *font = [NSFont systemFontOfSize:fontSize weight:NSFontWeightBold];
		NSColor *fg = [NSColor labelColor];
		NSDictionary *attrs = @{ NSFontAttributeName: font,
			NSForegroundColorAttributeName: fg };
		NSAttributedString *as = [[[NSAttributedString alloc] initWithString:NSLocalizedString(@"Notation", @"App name") attributes:attrs] autorelease];
		[titleLabel setAttributedStringValue:as];
		[titleLabel sizeToFit];

		NSSize labelSize = [titleLabel frame].size;
		// Add a little horizontal padding
		CGFloat padX = 4.0;
		NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, labelSize.width + padX * 2, labelSize.height)];
		[[container.widthAnchor constraintEqualToConstant:labelSize.width + padX * 2] setActive:YES];
		[[container.heightAnchor constraintEqualToConstant:labelSize.height] setActive:YES];
		[titleLabel setFrameOrigin:NSMakePoint(padX, 0)];
		[container addSubview:titleLabel];

		[appTitleItem setView:container];
		[appTitleItem setLabel:NSLocalizedString(@"Notation", @"App name")];
	}

	window.titleVisibility = NSWindowTitleHidden;

	// Keep the title visible and push it to the left by centering our field
	window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleLine;
	window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    [dualFieldItem setLabel:NSLocalizedString(@"Search or Create", @"placeholder text in search/create field")];

	toolbar = [[NSToolbar alloc] initWithIdentifier:@"NVToolbar"];
	[toolbar setAllowsUserCustomization:NO];
	[toolbar setAutosavesConfiguration:NO];
	[toolbar setDisplayMode:NSToolbarDisplayModeIconOnly];
//	[toolbar setSizeMode:NSToolbarSizeModeRegular];
	[toolbar setShowsBaselineSeparator:YES];
	[toolbar setVisible:![[NSUserDefaults standardUserDefaults] boolForKey:@"ToolbarHidden"]];
	[toolbar setDelegate:self];
	[window setToolbar:toolbar];

	[window setShowsToolbarButton:NO];
	titleBarButton = [[TitlebarButton alloc] initWithFrame:NSMakeRect(0, 0, 17.0, 17.0) pullsDown:YES];
	[titleBarButton addToWindow:window];

//	[window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];

	[NSWindow setAllowsAutomaticWindowTabbing:NO];

	[NSApp setDelegate:self];
	[notesTableView setDelegate:self];
	[window setDelegate:self];
	[field setDelegate:self];
	[textView setDelegate:self];
	[splitView setDelegate:self];

	//set up temporary FastListDataSource containing false visible notes

	//[window makeKeyAndOrderFront:self];
	//[self setEmptyViewState:YES];

	outletObjectAwoke(self);
}

//really need make AppController a subclass of NSWindowController and stick this junk in windowDidLoad
- (void)setupViewsAfterAppAwakened {
	static BOOL awakenedViews = NO;
	if (!awakenedViews) {
		//NSLog(@"all (hopefully relevant) views awakend!");
		[self _configureDividerForCurrentLayout];
		[splitView restoreState:YES];

		[splitSubview addSubview:editorStatusView positioned:NSWindowAbove relativeTo:splitSubview];
		[editorStatusView setFrame:[[textView enclosingScrollView] frame]];

		[notesTableView restoreColumns];

		[field setNextKeyView:textView];
		[textView setNextKeyView:field];
		[window setAutorecalculatesKeyViewLoop:NO];

		[self setEmptyViewState:YES];

		//this is necessary on 10.3; keep just in case
		[splitView display];

		awakenedViews = YES;
	}
}

//what a hack
void outletObjectAwoke(id sender) {
	static NSMutableSet *awokenOutlets = nil;
	if (!awokenOutlets) awokenOutlets = [[NSMutableSet alloc] initWithCapacity:5];

	[awokenOutlets addObject:sender];

	AppController* appDelegate = (AppController*)[NSApp delegate];

	if (appDelegate && [awokenOutlets containsObject:appDelegate] &&
		[awokenOutlets containsObject:appDelegate->notesTableView] &&
		[awokenOutlets containsObject:appDelegate->textView] &&
		[awokenOutlets containsObject:appDelegate->editorStatusView] &&
		[awokenOutlets containsObject:appDelegate->splitView]) {

		[appDelegate setupViewsAfterAppAwakened];
	}
}

- (void)runDelayedUIActionsAfterLaunch {
	[[prefsController bookmarksController] setAppController:self];
	[[prefsController bookmarksController] restoreWindowFromSave];
	[[prefsController bookmarksController] updateBookmarksUI];
	[self updateNoteMenus];
	[textView setupFontMenu];
	[prefsController registerAppActivationKeystrokeWithTarget:self selector:@selector(toggleNVActivation:)];
	[notationController checkIfNotationIsTrashed];
	[[SecureTextEntryManager sharedInstance] checkForIncompatibleApps];

	// Connect Sparkle programmatically to avoid loading its framework at nib awake
	Class SPUControllerClass = NSClassFromString(@"SPUStandardUpdaterController");
	if (!SPUControllerClass) {
		if (![[NSBundle bundleWithPath:[[[NSBundle bundleForClass:[self class]] privateFrameworksPath] stringByAppendingPathComponent:@"Sparkle.framework"]] load]) {
			NSLog(@"Could not load Sparkle framework!");
		}
		SPUControllerClass = NSClassFromString(@"SPUStandardUpdaterController");
	}

	if (SPUControllerClass) {
		sparkleController = [[SPUControllerClass alloc] performSelector:NSSelectorFromString(@"initWithUpdaterDelegate:userDriverDelegate:") withObject:nil withObject:nil];
		[sparkleUpdateItem setTarget:sparkleController];
		[sparkleUpdateItem setAction:@selector(checkForUpdates:)];
		// Enable automatic checks after the first launch, if updater is available
		SEL updaterSEL = NSSelectorFromString(@"updater");
		if ([sparkleController respondsToSelector:updaterSEL]) {
			id updater = [sparkleController performSelector:updaterSEL];
			if (![[prefsController notationPrefs] firstTimeUsed]) {
				[updater setAutomaticallyChecksForUpdates:YES];
			}
		}
	}

	[NSApp setServicesProvider:self];
}

- (void)applicationDidFinishLaunching:(NSNotification*)aNote {

	//on tiger dualfield is often not ready to add tracking tracks until this point:
	[field setTrackingRect];

    NSDate *before = [NSDate date];
	prefsWindowController = [[PrefsWindowController alloc] init];

	OSStatus err = noErr;
	NotationController *newNotation = nil;
	BOOL hasSavedDirectory = [prefsController bookmarkDataForDefaultDirectory] != nil ||
		[prefsController aliasDataForDefaultDirectory] != nil;
	NSURL *savedDirectoryURL = [prefsController defaultDirectoryURLResolvingBookmark:NULL error:NULL];

	NSString *subMessage = @"";

	BOOL skipDefaultInitialization = (kCGEventFlagMaskAlternate == (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & (CGEventFlags)NSEventModifierFlagDeviceIndependentFlagsMask));

	if (!skipDefaultInitialization) {
		if (hasSavedDirectory) {
		    newNotation = savedDirectoryURL ? [[NotationController alloc] initWithDirectoryURL:savedDirectoryURL error:&err] : nil;
			if (!savedDirectoryURL) err = fnfErr;
		    subMessage = NSLocalizedString(@"Please choose a different folder in which to store your notes.",nil);
		} else {
		    newNotation = [[NotationController alloc] initWithDefaultDirectoryReturningError:&err];
		    subMessage = NSLocalizedString(@"Please choose a folder in which your notes will be stored.",nil);
		}
	}

	NSURL *displayDirectoryURL = [NSURL URLByResolvingBookmarkData:[prefsController bookmarkDataForDefaultDirectory]
		options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];
	NSString *location = hasSavedDirectory ? [displayDirectoryURL path] : NSLocalizedString(@"your Application Support directory",nil);
	if (!location) location = NSLocalizedString(@"its current location",nil);

	NSURL *notesDirectoryURL = nil;
	BOOL shouldShowOpenPanel = skipDefaultInitialization || (newNotation == nil && err == kPassCanceledErr);

	while (!newNotation) {
		if (shouldShowOpenPanel) {
			if (![prefsWindowController getNewNotesURLFromOpenPanel:&notesDirectoryURL returnedPath:&location]) {
				//they cancelled the open panel, or it was unable to reference the directory
				goto terminateApp;
			}
				newNotation = [[NotationController alloc] initWithDirectoryURL:notesDirectoryURL error:&err];
				if (newNotation) {
					break;
			}
			shouldShowOpenPanel = NO;
			continue;
		}

	    location = [location stringByAbbreviatingWithTildeInPath];
	    NSString *reason = [NSString reasonStringFromCarbonFSError:err];

	    NSAlert *initializationAlert = [[[NSAlert alloc] init] autorelease];
	    [initializationAlert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Unable to initialize notes database in \n%@ because %@.", nil), location, reason]];
	    [initializationAlert setInformativeText:subMessage];
	    [initializationAlert addButtonWithTitle:NSLocalizedString(@"Choose another folder", nil)];
	    [initializationAlert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
	    NSModalResponse initializationResponse = [initializationAlert runModal];
	    if (initializationResponse == NSAlertFirstButtonReturn) {
			//show nsopenpanel, defaulting to current default notes dir
			shouldShowOpenPanel = YES;
			continue;
	    } else {
			goto terminateApp;
	    }
	}

	[self setNotationController:newNotation];
	[newNotation release];

	NSLog(@"load time: %g, ",[[NSDate date] timeIntervalSinceDate:before]);
	//	NSLog(@"version: %s", PRODUCT_NAME);

	//import old database(s) here if necessary
	[AlienNoteImporter importBlorOrHelpFilesIfNecessaryIntoNotation:newNotation];

	if (URLToInterpretOnLaunch) {
		[self interpretNVURL:[URLToInterpretOnLaunch autorelease]];
		URLToInterpretOnLaunch = nil;
	}

	//tell us..
	[prefsController registerWithTarget:self forChangesInSettings:
	 @selector(setDefaultDirectoryURL:sender:error:),  //when someone wants to load a new database
	 @selector(setSortedTableColumnKey:reversed:sender:),  //when sorting prefs changed
	 @selector(setNoteBodyFont:sender:),  //when to tell notationcontroller to restyle its notes
	 @selector(setForegroundTextColor:sender:),  //ditto
	 @selector(setTableFontSize:sender:),  //when to tell notationcontroller to regenerate the (now potentially too-short) note-body previews
	 @selector(addTableColumn:sender:),  //ditto
	 @selector(removeTableColumn:sender:),  //ditto
	 @selector(setTableColumnsShowPreview:sender:),  //when to tell notationcontroller to generate or disable note-body previews
	 @selector(setConfirmNoteDeletion:sender:),  //whether "delete note" should have an ellipsis
	 @selector(setAutoCompleteSearches:sender:), nil];   //when to tell notationcontroller to build its title-prefix connections

	if (pathsToOpenOnLaunch) {
		NSArray *launchPaths = [pathsToOpenOnLaunch autorelease];
		pathsToOpenOnLaunch = nil;
		[self importFilePaths:launchPaths usingImporter:nil];
	}

	[self performSelector:@selector(runDelayedUIActionsAfterLaunch) withObject:nil afterDelay:0.0];

	return;
terminateApp:
	[NSApp terminate:self];
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {

	NSURL *fullURL = [NSURL URLWithString:[[event paramDescriptorForKeyword:keyDirectObject] stringValue]];

	if (notationController) {
		if (![self interpretNVURL:fullURL])
			NSBeep();
	} else {
		URLToInterpretOnLaunch = [fullURL retain];
	}
}

- (void)setNotationController:(NotationController*)newNotation {

    if (newNotation) {
		if (notationController) {
			[notationController closeAllResources];
			[[NSNotificationCenter defaultCenter] removeObserver:self name:SyncSessionsChangedVisibleStatusNotification
														  object:[notationController syncSessionController]];
		}

		NotationController *oldNotation = notationController;
		notationController = [newNotation retain];

		if (oldNotation) {
			[notesTableView abortEditing];
			[prefsController setLastSearchString:[self fieldSearchString] selectedNote:currentNote
						scrollOffsetForTableView:notesTableView sender:self];
			//if we already had a notation, appController should already be bookmarksController's delegate
			[[prefsController bookmarksController] performSelector:@selector(updateBookmarksUI) withObject:nil afterDelay:0.0];
		}
		[notationController setSortColumn:[notesTableView noteAttributeColumnForIdentifier:[prefsController sortedTableColumnKey]]];
		[notesTableView setDataSource:[notationController notesListDataSource]];
		[notesTableView setLabelsListSource:[notationController labelsListDataSource]];
		[notationController setDelegate:self];

		//allow resolution of UUIDs to NoteObjects from saved searches
		[[prefsController bookmarksController] setDataSource:notationController];

		//update the list using the new notation and saved settings
		[self restoreListStateUsingPreferences];

		//window's undomanager could be referencing actions from the old notation object
		[windowUndoManager removeAllActions];
		[notationController setUndoManager:windowUndoManager];

			[prefsController setDefaultDirectoryURL:[notationController noteDirectoryURL] sender:self error:NULL];
		if ([prefsController tableColumnsShowPreview] || [prefsController horizontalLayout]) {
			[self _forceRegeneratePreviewsForTitleColumn];
			[notesTableView setNeedsDisplay:YES];
		}
		[titleBarButton setMenu:[[notationController syncSessionController] syncStatusMenu]];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncSessionsChangedVisibleStatus:)
													 name:SyncSessionsChangedVisibleStatusNotification
												   object:[notationController syncSessionController]];

		//these should probably be triggered from within NotationController:
		[notationController performSelector:@selector(startSyncServices) withObject:nil afterDelay:0.0];

		if ([[notationController notationPrefs] secureTextEntry]) {
			[[SecureTextEntryManager sharedInstance] enableSecureTextEntry];
		} else {
			[[SecureTextEntryManager sharedInstance] disableSecureTextEntry];
		}

		[field selectText:nil];

		[oldNotation autorelease];
    }
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    if (![prefsController quitWhenClosingWindow]) {
        [self bringFocusToControlField:nil];
        return YES;
    }

    return NO;
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
	if ([itemIdentifier isEqualToString:@"AppTitleLabel"]) return appTitleItem;
	if ([itemIdentifier isEqualToString:@"DualField"]) return dualFieldItem;
	return nil;
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar*)theToolbar {
	return [self toolbarDefaultItemIdentifiers:theToolbar];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)theToolbar {
	return @[ @"AppTitleLabel", @"DualField" ];
}


- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
	SEL selector = [menuItem action];
	NSInteger numberSelected = [notesTableView numberOfSelectedRows];

	if (selector == @selector(printNote:) ||
		selector == @selector(deleteNote:) ||
		selector == @selector(exportNote:) ||
		selector == @selector(tagNote:)) {

		return (numberSelected > 0);

	} else if (selector == @selector(renameNote:) ||
			   selector == @selector(copyNoteLink:)) {

		return (numberSelected == 1);

	} else if (selector == @selector(revealNote:)) {

		return (numberSelected == 1) && [notationController currentNoteStorageFormat] != SingleDatabaseFormat;

	} else if (selector == @selector(fixFileEncoding:)) {

		return (currentNote != nil && storageFormatOfNote(currentNote) == PlainTextFormat && ![currentNote contentsWere7Bit]);
	} else if (selector == @selector(editNoteExternally:)) {

		return (numberSelected > 0) && [[menuItem representedObject] canEditAllNotes:
										[notationController notesAtIndexes:[notesTableView selectedRowIndexes]]];
	}

	return YES;
}

- (void)updateNoteMenus {
	NSMenu *notesMenu = [[[NSApp mainMenu] itemWithTag:NOTES_MENU_ID] submenu];

	NSInteger menuIndex = [notesMenu indexOfItemWithTarget:self andAction:@selector(deleteNote:)];
	NSMenuItem *deleteItem = nil;
	if (menuIndex > -1 && (deleteItem = [notesMenu itemAtIndex:menuIndex]))	{
		NSString *trailingQualifier = [prefsController confirmNoteDeletion] ? NSLocalizedString(@"...", @"ellipsis character") : @"";
		[deleteItem setTitle:[NSString stringWithFormat:@"%@%@",
							  NSLocalizedString(@"Delete", nil), trailingQualifier]];
	}

	[notesMenu setSubmenu:[[ExternalEditorListController sharedInstance] addEditNotesMenu] forItem:[notesMenu itemWithTag:88]];

	NSMenu *viewMenu = [[[NSApp mainMenu] itemWithTag:VIEW_MENU_ID] submenu];

	menuIndex = [viewMenu indexOfItemWithTarget:notesTableView andAction:@selector(toggleNoteBodyPreviews:)];
	NSMenuItem *bodyPreviewItem = nil;
	if (menuIndex > -1 && (bodyPreviewItem = [viewMenu itemAtIndex:menuIndex])) {
		[bodyPreviewItem setTitle: [prefsController tableColumnsShowPreview] ?
		 NSLocalizedString(@"Hide Note Previews in Title", @"menu item in the View menu to turn off note-body previews in the Title column") :
		 NSLocalizedString(@"Show Note Previews in Title", @"menu item in the View menu to turn on note-body previews in the Title column")];
	}
	menuIndex = [viewMenu indexOfItemWithTarget:self andAction:@selector(switchViewLayout:)];
	NSMenuItem *switchLayoutItem = nil;
	if (menuIndex > -1 && (switchLayoutItem = [viewMenu itemAtIndex:menuIndex])) {
		[switchLayoutItem setTitle:[prefsController horizontalLayout] ?
		 NSLocalizedString(@"Switch to Vertical Layout", @"title of alternate view layout menu item") :
		 NSLocalizedString(@"Switch to Horizontal Layout", @"title of view layout menu item")];
	}
}

- (void)_forceRegeneratePreviewsForTitleColumn {
	[notationController regeneratePreviewsForColumn:[notesTableView noteAttributeColumnForIdentifier:NoteTitleColumnString]
								visibleFilteredRows:[notesTableView rowsInRect:[notesTableView visibleRect]] forceUpdate:YES];
}

- (void)_configureDividerForCurrentLayout {
	BOOL horiz = [prefsController horizontalLayout];
	[splitView setVertical:horiz];

	if (!verticalDividerImg && [splitView divider]) verticalDividerImg = [[splitView divider] retain];
	[splitView setDivider: horiz ? nil : verticalDividerImg];
	[splitView setDividerThickness: horiz ? 0.0 : 8.0];

	[[notesTableView enclosingScrollView] setBorderType: horiz ? NSNoBorder : NSBezelBorder];

	NSSize size = [[splitView subviewAtPosition:0] frame].size;
	[[notesTableView enclosingScrollView] setFrame: horiz ? NSMakeRect(1, 0, size.width - 1, size.height - 1) : (NSRect){.size = size, .origin = NSZeroPoint}];

	[[splitView subviewAtPosition:0] setMinDimension:horiz ? 100.0 : 0.0 andMaxDimension:0.0];
	[splitSubview setMinDimension:horiz ? 100.0 : 0.0 andMaxDimension:0.0];
}

- (IBAction)switchViewLayout:(id)sender {
	ViewLocationContext ctx = [notesTableView viewingLocation];
	ctx.pivotRowWasEdge = NO;
	[notesTableView noteFirstVisibleRow];

	[self _expandToolbar];

	[prefsController setHorizontalLayout:![prefsController horizontalLayout] sender:self];
	[notationController updateDateStringsIfNecessary];
	[self _configureDividerForCurrentLayout];
	[notationController regenerateAllPreviews];
	[splitView adjustSubviews];

	[notesTableView setViewingLocation:ctx];
	[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];

	[self updateNoteMenus];
}

- (void)createFromSelection:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
	if (!notationController || ![self addNotesFromPasteboard:pboard]) {
		*error = NSLocalizedString(@"Error: Couldn't create a note from the selection.", @"error message to set during a Service call when adding a note failed");
	}
}



- (IBAction)renameNote:(id)sender {
    //edit the first selected note
	[notesTableView editRowAtColumnWithIdentifier:NoteTitleColumnString];
}

- (IBAction)deleteNote:(id)sender {
	if ([window attachedSheet]) return;

	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	if ([indexes count] > 0) {
	id deleteObj = [indexes count] > 1 ? (id)([notationController notesAtIndexes:indexes]) : (id)([notationController noteObjectAtFilteredIndex:(int)[indexes firstIndex]]);

		BOOL hasExternalEditingSession = NO;
		NSArray *notesToDelete = [deleteObj isKindOfClass:[NSArray class]] ? deleteObj : @[ deleteObj ];
		for (NoteObject *note in notesToDelete)
			if ([[ExternalEditingSession sharedExternalEditingSession] hasActiveScratchEditingSessionForClient:note]) {
				hasExternalEditingSession = YES;
				break;
			}

		if ([prefsController confirmNoteDeletion] || hasExternalEditingSession) {
			[deleteObj retain];
			NSString *warningSingleFormatString = NSLocalizedString(@"Delete the note titled quotemark%@quotemark?", @"alert title when asked to delete a note");
			NSString *warningMultipleFormatString = NSLocalizedString(@"Delete %d notes?", @"alert title when asked to delete multiple notes");
			NSString *warnString = currentNote ? [NSString stringWithFormat:warningSingleFormatString, titleOfNote(currentNote)] :
			[NSString stringWithFormat:warningMultipleFormatString, (int)[indexes count]];

			NSAlert *alert = [[[NSAlert alloc] init] autorelease];
			[alert setMessageText:warnString];
			[alert setInformativeText:hasExternalEditingSession ? NSLocalizedString(
				@"External editing will end. Notational Velocity will preserve changes saved so far, then remove the temporary file. Later changes made in the external editor's remaining buffer cannot be recovered.", nil) :
				NSLocalizedString(@"Press Command-Z to undo this action later.", @"informational delete-this-note? text")];
			[alert addButtonWithTitle:NSLocalizedString(@"Delete", @"name of delete button")];
			[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"name of cancel button")];
			[alert setShowsSuppressionButton:!hasExternalEditingSession];

			[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
				if (response == NSAlertFirstButtonReturn) {
					//ensure that there are no pending edits in the tableview,
					//lest editing end with the same field editor and a different selected note
					//resulting in the renaming of notes in adjacent rows
					[notesTableView abortEditing];

					if ([deleteObj isKindOfClass:[NSArray class]]) {
						[notationController removeNotes:deleteObj];
					} else if ([deleteObj isKindOfClass:[NoteObject class]]) {
						[notationController removeNote:deleteObj];
					}
					if (!hasExternalEditingSession &&
						[[alert suppressionButton] state] == NSControlStateValueOn) {
						[prefsController setConfirmNoteDeletion:NO sender:self];
					}
				}
				[deleteObj release];
			}];
		} else {
			//just delete the notes outright
			[notationController performSelector:[indexes count] > 1 ? @selector(removeNotes:) : @selector(removeNote:) withObject:deleteObj];
		}
	}
}

- (IBAction)copyNoteLink:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];

	if ([indexes count] == 1) {
		[[[[[notationController notesAtIndexes:indexes] lastObject]
		   uniqueNoteLink] absoluteString] copyItemToPasteboard:nil];
	}
}

- (IBAction)exportNote:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];

	NSArray *notes = [notationController notesAtIndexes:indexes];

	[notationController synchronizeNoteChanges:nil];
	[[ExporterManager sharedManager] exportNotes:notes forWindow:window];
}

- (IBAction)revealNote:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	NSURL *fileURL = nil;

	if ([indexes count] != 1 || !(fileURL = [[notationController noteObjectAtFilteredIndex:(int)[indexes lastIndex]] noteFileURL])) {
		NSBeep();
		return;
	}
	[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ fileURL ]];
}

- (IBAction)editNoteExternally:(id)sender {
	ExternalEditor *ed = [sender representedObject];
	if ([ed isKindOfClass:[ExternalEditor class]]) {
		NSIndexSet *indexes = [notesTableView selectedRowIndexes];

		if (kCGEventFlagMaskAlternate == (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & (CGEventFlags)NSEventModifierFlagDeviceIndependentFlagsMask)) {
			//allow changing the default editor directly from Notes menu
			[[ExternalEditorListController sharedInstance] setDefaultEditor:ed];
		}
		//force-write any queued changes to disk in case notes are being stored as separate files which might be opened directly by the method below
		[notationController synchronizeNoteChanges:nil];

		[[notationController notesAtIndexes:indexes] makeObjectsPerformSelector:@selector(editExternallyUsingEditor:) withObject:ed];
	} else {
		NSBeep();
	}
}

- (IBAction)printNote:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];

	[MultiplePageView printNotes:[notationController notesAtIndexes:indexes] forWindow:window];
}

- (IBAction)tagNote:(id)sender {
    //if single note, add the tag column if necessary and then begin editing
    NSIndexSet *indexes = [notesTableView selectedRowIndexes];

    if ([indexes count] > 1) {
        // Multiple Notes selected: present multitagging panel
        NSRect wFrame = [[self window] frame];
        NSPoint cPoint = NSMakePoint(NSMidX(wFrame), NSMaxY(wFrame));
        if (tagEditor) {
			self.tagEditor = nil;
        }
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(releaseTagEditor:) name:@"TagEditorShouldRelease" object:nil];
		self.tagEditor = [[[TagEditingManager alloc] initWithDelegate:self commonTags:[self commonLabelsForNotesAtIndexes:indexes] atPoint:cPoint] autorelease];
    } else if ([indexes count] == 1) {
        [notesTableView editRowAtColumnWithIdentifier:NoteLabelsColumnString];
    }
}

- (void)noteImporter:(AlienNoteImporter*)importer importedNotes:(NSArray*)notes {

	[notationController addNotes:notes];
}
- (IBAction)importNotes:(id)sender {
	AlienNoteImporter *importer = [[AlienNoteImporter alloc] init];
	[importer importNotesFromDialogAroundWindow:window receptionDelegate:self];
	[importer autorelease];
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
    if ([selectorString isEqualToString:SEL_STR(setDefaultDirectoryURL:sender:error:)]) {
		//defaults changed for the database location -- load the new one!
		NSURL *newURL = [prefsController defaultDirectoryURLResolvingBookmark:NULL error:NULL];
		ExternalEditingSession *editor = [ExternalEditingSession sharedExternalEditingSession];
		if (newURL && [editor activeScratchEditingSessionCount]) {
			NSURL *oldURL = [notationController noteDirectoryURL];
			if (![self _confirmEndingExternalEditingForAction:NSLocalizedString(@"Change Database", nil)
				continueButtonTitle:NSLocalizedString(@"Continue", nil)]) {
				[prefsController setDefaultDirectoryURL:oldURL sender:self error:NULL];
				return;
			}
			[editor beginScratchEditingSuspension];
			[editor finishAllScratchEditingSessionsWithCompletionHandler:^(BOOL success) {
				if (success) [self _loadNotationAtURL:newURL];
				else {
					[prefsController setDefaultDirectoryURL:oldURL sender:self error:NULL];
					[self externalEditingSessionTeardownFailed];
				}
				[editor endScratchEditingSuspension];
			}];
			return;
		}
		if (newURL) [self _loadNotationAtURL:newURL];
    } else if ([selectorString isEqualToString:SEL_STR(setSortedTableColumnKey:reversed:sender:)]) {
		NoteAttributeColumn *oldSortCol = [notationController sortColumn];
		NoteAttributeColumn *newSortCol = [notesTableView noteAttributeColumnForIdentifier:[prefsController sortedTableColumnKey]];
		BOOL changedColumns = oldSortCol != newSortCol;

		ViewLocationContext ctx;
		if (changedColumns) {
			ctx = [notesTableView viewingLocation];
			ctx.pivotRowWasEdge = NO;
		}

		[notationController setSortColumn:newSortCol];

		if (changedColumns) [notesTableView setViewingLocation:ctx];

	} else if ([selectorString isEqualToString:SEL_STR(setNoteBodyFont:sender:)]) {

		[notationController restyleAllNotes];
		if (currentNote) {
			[self contentsUpdatedForNote:currentNote];
		}
	} else if ([selectorString isEqualToString:SEL_STR(setForegroundTextColor:sender:)]) {

		[notationController setForegroundTextColor:[prefsController foregroundTextColor]];
		if (currentNote) {
			[self contentsUpdatedForNote:currentNote];
		}
	} else if ([selectorString isEqualToString:SEL_STR(setTableFontSize:sender:)] || [selectorString isEqualToString:SEL_STR(setTableColumnsShowPreview:sender:)]) {

		ResetFontRelatedTableAttributes();
		[notesTableView updateTitleDereferencorState];
		[[notationController labelsListDataSource] invalidateCachedLabelImages];
		[self _forceRegeneratePreviewsForTitleColumn];

		if ([selectorString isEqualToString:SEL_STR(setTableColumnsShowPreview:sender:)]) [self updateNoteMenus];

		[notesTableView performSelector:@selector(reloadData) withObject:nil afterDelay:0];
	} else if ([selectorString isEqualToString:SEL_STR(addTableColumn:sender:)] || [selectorString isEqualToString:SEL_STR(removeTableColumn:sender:)]) {

		ResetFontRelatedTableAttributes();
		[self _forceRegeneratePreviewsForTitleColumn];
		[notesTableView performSelector:@selector(reloadDataIfNotEditing) withObject:nil afterDelay:0];

	} else if ([selectorString isEqualToString:SEL_STR(setConfirmNoteDeletion:sender:)]) {
		[self updateNoteMenus];
	} else if ([selectorString isEqualToString:SEL_STR(setAutoCompleteSearches:sender:)]) {
		if ([prefsController autoCompleteSearches])
			[notationController updateTitlePrefixConnections];
	}

}

- (BOOL)_confirmEndingExternalEditingForAction:(NSString*)action
	continueButtonTitle:(NSString*)continueButtonTitle {
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:[NSString stringWithFormat:
		NSLocalizedString(@"%@ and end external editing?", nil), action]];
	[alert setInformativeText:NSLocalizedString(
		@"Notational Velocity will preserve changes saved so far, then remove its temporary files. Later changes made in an external editor's remaining buffer cannot be recovered.", nil)];
	[alert addButtonWithTitle:continueButtonTitle];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
	[alert setAlertStyle:NSAlertStyleWarning];
	return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)_restoreWindowAfterCanceledTermination {
	[syncWaitSpinner stopAnimation:nil];
	[syncWaitPanel orderOut:nil];
	waitedForUncommittedChanges = NO;
	[window makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];
}

- (void)_confirmQuittingExternalEditingWithCompletionHandler:
	(void (^)(BOOL shouldQuit))completionHandler {
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(
		@"%@ and end external editing?", nil), NSLocalizedString(@"Quit", nil)]];
	[alert setInformativeText:NSLocalizedString(
		@"Notational Velocity will preserve changes saved so far, then remove its temporary files. Later changes made in an external editor's remaining buffer cannot be recovered.", nil)];
	NSButton *quitButton = [alert addButtonWithTitle:NSLocalizedString(@"Quit Anyway", nil)];
	[quitButton setKeyEquivalent:@"\r"];
	NSButton *cancelButton = [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
	[cancelButton setKeyEquivalent:@"\e"];
	[alert setAlertStyle:NSAlertStyleWarning];
	/* AppKit is already deciding whether to terminate here. Present the choice on
	 * the next run-loop turn, after applicationShouldTerminate: has returned
	 * NSTerminateLater, so either button can finish that decision exactly once. */
	dispatch_async(dispatch_get_main_queue(), ^{
		completionHandler([self _externalEditingQuitResponseShouldTerminate:[alert runModal]]);
	});
	[alert release];
}

- (BOOL)_externalEditingQuitResponseShouldTerminate:(NSModalResponse)response {
	return response == NSAlertFirstButtonReturn;
}

- (void)_loadNotationAtURL:(NSURL*)newURL {
	OSStatus err = noErr;
	NotationController *newNotation = [[NotationController alloc]
		initWithDirectoryURL:newURL error:&err];
	if (newNotation) {
		[self setNotationController:newNotation];
		[newNotation release];
		return;
	}
	NSURL *oldURL = [notationController noteDirectoryURL];
	[prefsController setDefaultDirectoryURL:oldURL sender:self error:NULL];
	NSString *location = [[newURL path] stringByAbbreviatingWithTildeInPath];
	NSString *oldLocation = [[oldURL path] stringByAbbreviatingWithTildeInPath];
	NSString *reason = [NSString reasonStringFromCarbonFSError:err];
	NSAlert *revertAlert = [[[NSAlert alloc] init] autorelease];
	[revertAlert setMessageText:[NSString stringWithFormat:NSLocalizedString(
		@"Unable to initialize notes database in \n%@ because %@.", nil), location, reason]];
	[revertAlert setInformativeText:[NSString stringWithFormat:NSLocalizedString(
		@"Reverting to current location of %@.", nil), oldLocation]];
	[revertAlert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
	[revertAlert runModal];
}

#pragma mark - Multitagging

- (NSArray *)commonLabelsForNotesAtIndexes:(NSIndexSet *)selDexes {
    NSArray *retArray = [NSArray array];
    NSArray *selectedNotes = [notationController notesAtIndexes:selDexes];
    NSEnumerator *noteEnum = [[selectedNotes objectEnumerator] retain];
    NoteObject *aNote = [noteEnum nextObject];
    NSString *existTags = labelsOfNote(aNote);
    if (existTags && (existTags.length > 0)) {
        NSMutableSet *commonTags = [NSMutableSet new];
        [commonTags addObjectsFromArray:[existTags labelCompatibleWords]];
        while (((aNote = [noteEnum nextObject])) && ([commonTags count] > 0)) {
            existTags = labelsOfNote(aNote);
            if (!existTags || (existTags.length == 0)) {
                [commonTags removeAllObjects];
                break;
            } else {
                NSArray *tagArray = [existTags labelCompatibleWords];
                if (tagArray && ([tagArray count] > 0)) {
                    NSSet *tagsForNote = [NSSet setWithArray:tagArray];
                    if ([commonTags intersectsSet:tagsForNote]) {
                        [commonTags intersectSet:tagsForNote];
                    } else {
                        [commonTags removeAllObjects];
                        break;
                    }
                } else {
                    [commonTags removeAllObjects];
                    break;
                }
            }
        }
        if ([commonTags count] > 0) {
            retArray = [NSArray arrayWithArray:[commonTags allObjects]];
        }
        [commonTags release];
    }
    [noteEnum release];
    return retArray;
}

- (IBAction)multiTag:(id)sender {
    if (!tagEditor) return;
    NSString *tagString = [tagEditor.tagFieldString stringByTrimmingCharactersInSet:[NSCharacterSet labelSeparatorCharacterSet]];
    NSArray *newTags = nil;
    if (tagString && (tagString.length > 0)) {
        newTags = [tagString labelCompatibleWords];
    } else {
        newTags = [NSArray array];
    }
    NSArray *commonLabs = tagEditor.commonTags;
    if (![newTags isEqualToArray:commonLabs]) {
        NSArray *selNotes = [notationController notesAtIndexes:[notesTableView selectedRowIndexes]];
        if (!selNotes || ([selNotes count] == 0)) {
            return;
        }
        tagString = nil;
        BOOL gotNewLabels = (newTags && ([newTags count] > 0));
        BOOL gotCommonLabels = (commonLabs && ([commonLabs count] > 0));
        NSPredicate *pred;
        NSMutableArray *finalTags = [NSMutableArray new];
        for (NoteObject *aNote in selNotes) {
            NSString *separator = @" ";
            tagString = labelsOfNote(aNote);
            NSArray *filteredTags = nil;
            if (tagString && (tagString.length > 0)) {
                if (([tagString rangeOfString:@","].location != NSNotFound)) {
                    separator = @",";
                }
                filteredTags = [tagString labelCompatibleWords];
                if (gotCommonLabels) {
                    pred = [NSPredicate predicateWithFormat:@"NOT %@ CONTAINS[cd] SELF", commonLabs];
                    filteredTags = [filteredTags filteredArrayUsingPredicate:pred];
                }
                if (filteredTags && ([filteredTags count] > 0)) {
                    [finalTags addObjectsFromArray:filteredTags];
                }
            }
            if (gotNewLabels) {
                if ([finalTags count] > 0) {
                    pred = [NSPredicate predicateWithFormat:@"NOT %@ CONTAINS[cd] SELF", finalTags];
                    filteredTags = [newTags filteredArrayUsingPredicate:pred];
                    if (filteredTags && ([filteredTags count] > 0)) {
                        [finalTags addObjectsFromArray:filteredTags];
                    }
                } else {
                    [finalTags addObjectsFromArray:newTags];
                }
            }
            if ([finalTags count] > 0) {
                tagString = [finalTags componentsJoinedByString:separator];
            } else {
                tagString = @"";
            }
            [aNote setLabelString:tagString];
            [finalTags removeAllObjects];
        }
        [notesTableView scrollRowToVisible:[[notesTableView selectedRowIndexes] firstIndex]];
        [finalTags release];
    }
    [tagEditor closeTP:self];
}

- (void)releaseTagEditor:(NSNotification *)note {
    if (tagEditor) {
		self.tagEditor = nil;
        [[NSNotificationCenter defaultCenter] removeObserver:self name:@"TagEditorShouldRelease" object:nil];
    }
}


- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn {
    if (tableView == notesTableView) {
		//this sets global prefs options, which ultimately calls back to us
		[notesTableView setStatusForSortedColumn:tableColumn];
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldShowCellExpansionForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
	return ![[tableColumn identifier] isEqualToString:NoteTitleColumnString];
}

- (IBAction)showHelpDocument:(id)sender {
	NSString *path = nil;

	switch ([sender tag]) {
		case 1:		//shortcuts
			path = [[NSBundle mainBundle] pathForResource:NSLocalizedString(@"Excruciatingly Useful Shortcuts", nil) ofType:@"nvhelp" inDirectory:nil];
		case 2:		//acknowledgments
			if (!path) path = [[NSBundle mainBundle] pathForResource:@"Acknowledgments" ofType:@"txt" inDirectory:nil];
			NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
			NSURL *textEditURL = [workspace URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"];
			if (textEditURL) {
				[workspace openURLs:@[ [NSURL fileURLWithPath:path] ] withApplicationAtURL:textEditURL
					configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
			}
			break;
		case 3:		//product site
			[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:NSLocalizedString(@"SiteURL", nil)]];
			break;
		case 4:		//development site
			[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://notational.net/development"]];
			break;
		default:
			NSBeep();
	}
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames {

	if (notationController)
		[self importFilePaths:filenames usingImporter:nil];
	else
		pathsToOpenOnLaunch = [filenames mutableCopyWithZone:nil];

	[NSApp replyToOpenOrPrint:[filenames count] ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
}
- (void)applicationDidBecomeActive:(NSNotification *)aNotification {
	[notationController checkJournalExistence];

    if ([notationController currentNoteStorageFormat] != SingleDatabaseFormat)
		[notationController performSelector:@selector(synchronizeNotesFromDirectory) withObject:nil afterDelay:0.0];

	[notationController updateDateStringsIfNecessary];
}

- (void)applicationWillResignActive:(NSNotification *)aNotification {
	//sync note files when switching apps so user doesn't have to guess when they'll be updated
	[notationController synchronizeNoteChanges:nil];
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
	static NSMenu *dockMenu = nil;
	if (!dockMenu) {
		dockMenu = [[NSMenu alloc] initWithTitle:@"NV Dock Menu"];
		[[dockMenu addItemWithTitle:NSLocalizedString(@"Add New Note from Clipboard", @"menu item title in dock menu")
							 action:@selector(paste:) keyEquivalent:@""] setTarget:notesTableView];
	}
	return dockMenu;
}

- (void)cancel:(id)sender {
	//fallback for when other views are hidden/removed during toolbar collapse
	[self cancelOperation:sender];
}

- (void)cancelOperation:(id)sender {
	//simulate a search for nothing

	[field setStringValue:@""];
	typedStringIsCached = NO;

	[notationController filterNotesFromString:@""];

	[notesTableView deselectAll:sender];
	[self _expandToolbar];

	[field selectText:sender];
	[[field cell] setShowsClearButton:NO];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)aTextView doCommandBySelector:(SEL)command {
    if (control == (NSControl*)field) {

		//backwards-searching is slow enough as it is, so why not just check this first?
		if (command == @selector(deleteBackward:))
			return NO;

		if (command == @selector(moveDown:) || command == @selector(moveUp:) ||
			//catch shift-up/down selection behavior
			command == @selector(moveDownAndModifySelection:) ||
			command == @selector(moveUpAndModifySelection:) ||
			command == @selector(moveToBeginningOfDocumentAndModifySelection:) ||
			command == @selector(moveToEndOfDocumentAndModifySelection:)) {

			BOOL singleSelection = ([notesTableView numberOfRows] == 1 && [notesTableView numberOfSelectedRows] == 1);
			[notesTableView keyDown:[window currentEvent]];

			NSUInteger strLen = [[aTextView string] length];
			if (!singleSelection && [aTextView selectedRange].length != strLen) {
				[aTextView setSelectedRange:NSMakeRange(0, strLen)];
			}

			return YES;
		}

		if ((command == @selector(insertTab:) || command == @selector(insertTabIgnoringFieldEditor:))) {
			//[self setEmptyViewState:NO];

			if (![[aTextView string] length]) {
				return YES;
			}
			if (!currentNote && [notationController preferredSelectedNoteIndex] != NSNotFound && [prefsController autoCompleteSearches]) {
				//if the current note is deselected and re-searching would auto-complete this search, then allow tab to trigger it
				[self searchForString:[self fieldSearchString]];
				return YES;
			} else if ([textView isHidden]) {
				return YES;
			}

			[window makeFirstResponder:textView];

			//don't eat the tab!
			return NO;
		}
		if (command == @selector(moveToBeginningOfDocument:)) {
		    [notesTableView selectRowAndScroll:0];
		    return YES;
		}
		if (command == @selector(moveToEndOfDocument:)) {
		    [notesTableView selectRowAndScroll:[notesTableView numberOfRows]-1];
		    return YES;
		}

		if (command == @selector(moveToBeginningOfLine:) || command == @selector(moveToLeftEndOfLine:)) {
			[aTextView moveToBeginningOfDocument:nil];
			return YES;
		}
		if (command == @selector(moveToEndOfLine:) || command == @selector(moveToRightEndOfLine:)) {
			[aTextView moveToEndOfDocument:nil];
			return YES;
		}

		if (command == @selector(moveToBeginningOfLineAndModifySelection:) || command == @selector(moveToLeftEndOfLineAndModifySelection:)) {

			if ([aTextView respondsToSelector:@selector(moveToBeginningOfDocumentAndModifySelection:)]) {
				[(id)aTextView performSelector:@selector(moveToBeginningOfDocumentAndModifySelection:)];
				return YES;
			}
		}
		if (command == @selector(moveToEndOfLineAndModifySelection:) || command == @selector(moveToRightEndOfLineAndModifySelection:)) {
			if ([aTextView respondsToSelector:@selector(moveToEndOfDocumentAndModifySelection:)]) {
				[(id)aTextView performSelector:@selector(moveToEndOfDocumentAndModifySelection:)];
				return YES;
			}
		}

		//we should make these two commands work for linking editor as well
		if (command == @selector(deleteToMark:)) {
			[aTextView deleteWordBackward:nil];
			return YES;
		}
		if (command == @selector(noop:)) {
			//control-U is not set to anything by default, so we have to check the event itself for noops
			NSEvent *event = [window currentEvent];
			if ([event modifierFlags] & NSEventModifierFlagControl) {
				if ([event firstCharacterIgnoringModifiers] == 'u') {
					//in 1.1.1 this deleted the entire line, like tcsh. this is more in-line with bash
					[aTextView deleteToBeginningOfLine:nil];
					return YES;
				}
			}
		}

    } else if (control == (NSControl*)notesTableView) {
        if (command == @selector(insertNewline:)) {
            //hit return in cell
            [window makeFirstResponder:textView];
            return YES;
        }
    } else if (tagEditor && control == [tagEditor tagField]) {
        if ((command == @selector(insertNewline:)) || (command == @selector(insertTab:))) {
            if ([aTextView selectedRange].length > 0) {
                NSString *fieldStr = [aTextView string];
                NSInteger len = fieldStr.length;
                if ((![fieldStr hasSuffix:@","]) && ![fieldStr hasSuffix:@" "]) {
                    [aTextView insertText:@"," replacementRange:NSMakeRange(len, 0)];
                    len++;
                }
                [aTextView setSelectedRange:NSMakeRange(len, 0)];
                return YES;
            }
        } else {
            if ((command == @selector(deleteBackward:)) || (command == @selector(deleteForward:))) {
                wasDeleting = YES;
            }
            return NO;
        }
    } else
        NSLog(@"%@/%@ got %@", [control description], [aTextView description], NSStringFromSelector(command));

	return NO;
}

- (void)_setCurrentNote:(NoteObject*)aNote {
	//save range of old current note
	//we really only want to save the insertion point position if it's currently invisible
	//how do we test that?
	BOOL wasAutomatic = NO;
	NSRange currentRange = [textView selectedRangeWasAutomatic:&wasAutomatic];
	if (!wasAutomatic) [currentNote setSelectedRange:currentRange];

	//regenerate content cache before switching to new note
	[currentNote updateContentCacheCStringIfNecessary];


	[currentNote release];
	currentNote = [aNote retain];
}

- (NoteObject*)selectedNoteObject {
	return currentNote;
}

- (NSArray*)selectedNotes {
	return [notationController notesAtIndexes:[notesTableView selectedRowIndexes]];
}

- (NSString*)fieldSearchString {
	NSString *typed = [self typedString];
	if (typed) return typed;

	if (!currentNote) return [field stringValue];

	return notationController.filterString;
}

- (NSString*)typedString {
	if (typedStringIsCached)
		return typedString;

	return nil;
}

- (void)cacheTypedStringIfNecessary:(NSString*)aString {
	if (!typedStringIsCached) {
		[typedString release];
		typedString = [(aString ? aString : [field stringValue]) copy];
		typedStringIsCached = YES;
	}
}

//from fieldeditor
- (void)controlTextDidChange:(NSNotification *)aNotification {

    if ([aNotification object] == field) {
		typedStringIsCached = NO;
		isFilteringFromTyping = YES;

		NSTextView *fieldEditor = [[aNotification userInfo] objectForKey:@"NSFieldEditor"];
		NSString *fieldString = [fieldEditor string];

		BOOL didFilter = [notationController filterNotesFromString:fieldString];

		if ([fieldString length] > 0) {
			[field setSnapbackString:nil];
			if (didFilter) {
				textView.lastFindSearchString = nil;
			}

			NSUInteger preferredNoteIndex = [notationController preferredSelectedNoteIndex];

			//lastLengthReplaced depends on textView:shouldChangeTextInRange:replacementString: being sent before controlTextDidChange: runs
			if ([prefsController autoCompleteSearches] && preferredNoteIndex != NSNotFound && ([field lastLengthReplaced] > 0)) {

				[notesTableView selectRowAndScroll:preferredNoteIndex];

				if (didFilter) {
					//current selection may be at the same row, but note at that row may have changed
					[self displayContentsForNoteAtIndex:(int)preferredNoteIndex];
				}

				NSAssert(currentNote != nil, @"currentNote must not--cannot--be nil!");

				NSRange typingRange = [fieldEditor selectedRange];

				//fill in the remaining characters of the title and select
				if ([field lastLengthReplaced] > 0 && typingRange.location < [titleOfNote(currentNote) length]) {

					[self cacheTypedStringIfNecessary:fieldString];

					NSAssert([fieldString isEqualToString:[fieldEditor string]], @"I don't think it makes sense for fieldString to change");

					NSString *remainingTitle = [titleOfNote(currentNote) substringFromIndex:typingRange.location];
					typingRange.length = [fieldString length] - typingRange.location;
					typingRange.length = MAX(typingRange.length, 0U);

					[fieldEditor replaceCharactersInRange:typingRange withString:remainingTitle];
					typingRange.length = [remainingTitle length];
					[fieldEditor setSelectedRange:typingRange];
				}

			} else {
				//auto-complete is off, search string doesn't prefix any title, or part of the search string is being removed
				goto selectNothing;
			}
		} else {
			//selecting nothing; nothing typed
		selectNothing:
			isFilteringFromTyping = NO;
			[notesTableView deselectAll:nil];

			//reloadData could have already de-selected us, and hence this notification would not be sent from -deselectAll:
			[self processChangedSelectionForTable:notesTableView];
		}

        isFilteringFromTyping = NO;
    } else if (tagEditor && [tagEditor isMultitagging]) {
        if (!isAutocompleting && !wasDeleting) {
            isAutocompleting = YES;
            NSTextView *editor = [tagEditor tagFieldEditor];
            NSRange selRange = [editor selectedRange];
            NSString *tagString = [NSString stringWithString:tagEditor.tagFieldString];
            NSString *searchString = tagString;
            if (selRange.length > 0) {
                searchString = [searchString substringWithRange:selRange];
            }
            searchString = [[searchString componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]] lastObject];
            selRange = [tagString rangeOfString:searchString options:NSBackwardsSearch];
            NSArray *theTags = [notesTableView labelCompletionsForString:searchString index:0];
            if ((theTags) && ([theTags count] > 0) && (![[theTags objectAtIndex:0] isEqualToString:@""])) {
                NSString *useStr = nil;
                for (useStr in theTags) {
                    if ([tagString rangeOfString:useStr].location == NSNotFound) {
                        break;
                    }
                }
                if (useStr) {
                    tagString = [tagString substringToIndex:selRange.location];
                    tagString = [tagString stringByAppendingString:useStr];
                    NSRange newSel = NSMakeRange(selRange.location + selRange.length, useStr.length - searchString.length);
                    [tagEditor setTF:tagString];
                    [editor setSelectedRange:newSel];
                }
            }
            isAutocompleting = NO;
        }
        wasDeleting = NO;
    }
}

- (void)tableViewSelectionIsChanging:(NSNotification *)aNotification {

	BOOL allowMultipleSelection = NO;
	NSEvent *event = [window currentEvent];

	NSEventType type = [event type];
	//do not allow drag-selections unless a modifier is pressed
	if (type == NSEventTypeLeftMouseDragged || type == NSEventTypeLeftMouseDown) {
		NSEventModifierFlags flags = [event modifierFlags];
		if ((flags & NSEventModifierFlagShift) || (flags & NSEventModifierFlagCommand)) {
			allowMultipleSelection = YES;
		}
	}

	if (allowMultipleSelection != [notesTableView allowsMultipleSelection]) {
		//we may need to hack some hidden NSTableView instance variables to improve mid-drag flags-changing
		//NSLog(@"set allows mult: %d", allowMultipleSelection);

		[notesTableView setAllowsMultipleSelection:allowMultipleSelection];

		//we need this because dragging a selection back to the same note will nto trigger a selectionDidChange notification
		[self performSelector:@selector(setTableAllowsMultipleSelection) withObject:nil afterDelay:0];
	}

	if ([window firstResponder] != notesTableView) {
		//occasionally changing multiple selection ability in-between selecting multiple items causes total deselection
		[window makeFirstResponder:notesTableView];
	}

	[self processChangedSelectionForTable:[aNotification object]];
}

- (void)setTableAllowsMultipleSelection {
	[notesTableView setAllowsMultipleSelection:YES];
	//NSLog(@"allow mult: %d", [notesTableView allowsMultipleSelection]);
	//[textView setNeedsDisplay:YES];
}

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification {
	NSEventType type = [[window currentEvent] type];
	if (type != NSEventTypeKeyDown && type != NSEventTypeKeyUp) {
		[self performSelector:@selector(setTableAllowsMultipleSelection) withObject:nil afterDelay:0];
	}

	[self processChangedSelectionForTable:[aNotification object]];
}

- (void)processChangedSelectionForTable:(NSTableView*)table {
	NSInteger selectedRow = [table selectedRow];
	NSInteger numberSelected = [table numberOfSelectedRows];

	NSTextView *fieldEditor = (NSTextView*)[field currentEditor];

	if (table == (NSTableView*)notesTableView) {

		if (selectedRow > -1 && numberSelected == 1) {
			//if it is uncached, cache the typed string only if we are selecting a note

			[self cacheTypedStringIfNecessary:[fieldEditor string]];

			//add snapback-button here?
			if (!isFilteringFromTyping && !isCreatingANote)
				[field setSnapbackString:typedString];

				if ([self displayContentsForNoteAtIndex:(int)selectedRow]) {

				[[field cell] setShowsClearButton:YES];

				//there doesn't seem to be any situation in which a note will be selected
				//while the user is typing and auto-completion is disabled, so should be OK

				if (!isFilteringFromTyping) {
					if ([toolbar isVisible]) {
						if (fieldEditor) {
							//the field editor has focus--select text, too
							[fieldEditor setString:titleOfNote(currentNote)];
							NSUInteger strLen = [titleOfNote(currentNote) length];
							if (strLen != [fieldEditor selectedRange].length)
								[fieldEditor setSelectedRange:NSMakeRange(0, strLen)];
						} else {
							//this could be faster
							[field setStringValue:titleOfNote(currentNote)];
						}
					} else {
						[window setTitle:titleOfNote(currentNote)];
					}
				}
			}
			return;
		}
	} else { //tags
#if 0
		if (numberSelected == 1)
			[notationController filterNotesFromLabelAtIndex:selectedRow];
		else if (numberSelected > 1)
			[notationController filterNotesFromLabelIndexSet:[table selectedRowIndexes]];
#endif
	}

	if (!isFilteringFromTyping) {
		if (currentNote) {
			//selected nothing and something is currently selected

			[self _setCurrentNote:nil];
			[field setShowsDocumentIcon:NO];

			if (typedStringIsCached) {
				//restore the un-selected state, but only if something had been first selected to cause that state to be saved
				[field setStringValue:typedString];
			}
			[textView setString:@""];
		}
		[self _expandToolbar];

		if (!currentNote) {
			if (selectedRow == -1 && (!fieldEditor || [window firstResponder] != fieldEditor)) {
				//don't select the field if we're already there
				[window makeFirstResponder:field];
				fieldEditor = (NSTextView*)[field currentEditor];
			}
			if (fieldEditor && [fieldEditor selectedRange].length)
				[fieldEditor setSelectedRange:NSMakeRange([[fieldEditor string] length], 0)];


			//remove snapback-button from dual field here?
			[field setSnapbackString:nil];

			if (!numberSelected) {
				if (savedSelectedNotes) {
					//savedSelectedNotes needs to be empty after de-selecting all notes,
					//to ensure that any delayed list-resorting does not re-select savedSelectedNotes

					self.savedSelectedNotes = nil;
				}
				[notesTableView setNeedsDisplay:YES]; //edge case of deselecting a note at row 0 with no other changes
			}
		}
	}
	[self setEmptyViewState:currentNote == nil];
	[field setShowsDocumentIcon:currentNote != nil];
	[[field cell] setShowsClearButton:currentNote != nil || [[field stringValue] length]];
}

- (void)setEmptyViewState:(BOOL)state {
    //return;

	//int numberSelected = [notesTableView numberOfSelectedRows];
	BOOL enable = /*numberSelected != 1;*/ state;
	[textView clearFindPanel];
	[textView setHidden:enable];
	[editorStatusView setHidden:!enable];

	if (enable) {
		[editorStatusView setLabelStatus:(int)[notesTableView numberOfSelectedRows]];
	}
}

- (BOOL)displayContentsForNoteAtIndex:(int)noteIndex {
	NoteObject *note = [notationController noteObjectAtFilteredIndex:noteIndex];
	if (note != currentNote) {
		[self setEmptyViewState:NO];
		[field setShowsDocumentIcon:YES];

		//actually load the new note
		[self _setCurrentNote:note];

		NSRange firstFoundTermRange = NSMakeRange(NSNotFound,0);
		NSRange noteSelectionRange = [currentNote lastSelectedRange];

		if (noteSelectionRange.location == NSNotFound ||
			NSMaxRange(noteSelectionRange) > [[note contentString] length]) {
			//revert to the top; selection is invalid
			noteSelectionRange = NSMakeRange(0,0);
		}

		//[textView beginInhibitingUpdates];
		//scroll to the top first in the old note body if necessary, because the text will (or really ought to) have already been laid-out
		//if ([textView visibleRect].origin.y > 0)
		//	[textView scrollRangeToVisible:NSMakeRange(0,0)];

		if (![textView didRenderFully]) {
			//NSLog(@"redisplay because last note was too long to finish before we switched");
			[textView setNeedsDisplayInRect:[textView visibleRect] avoidAdditionalLayout:YES];
		}

		//restore string
		[[textView textStorage] setAttributedString:[note contentString]];

		//[textView setAutomaticallySelectedRange:NSMakeRange(0,0)];

		//highlight terms--delay this, too
		if ((unsigned)noteIndex != [notationController preferredSelectedNoteIndex])
			firstFoundTermRange = [textView highlightTermsTemporarilyReturningFirstRange:typedString avoidHighlight:
								   ![prefsController highlightSearchTerms]];

		//if there was nothing selected, select the first found range
		if (!noteSelectionRange.length && firstFoundTermRange.location != NSNotFound)
			noteSelectionRange = firstFoundTermRange;

		//select and scroll
		[textView setAutomaticallySelectedRange:noteSelectionRange];
		[textView scrollRangeToVisible:noteSelectionRange];
		
		[textView setNeedsDisplay:YES]; //forces more pixels to draw but fixes missing paragraphs

		//NSString *words = noteIndex != [notationController preferredSelectedNoteIndex] ? typedString : nil;
		//[textView setFutureSelectionRange:noteSelectionRange highlightingWords:words];
		[textView clearFindPanel];

		return YES;
	}

	return NO;
}

//from linkingeditor
- (void)textDidChange:(NSNotification *)aNotification {
	id textObject = [aNotification object];

	if (textObject == textView) {
		[currentNote setContentString:[textView textStorage]];
	}
}

- (void)textDidBeginEditing:(NSNotification *)aNotification {
	if ([aNotification object] == textView) {
		[textView removeHighlightedTerms];
	    [self createNoteIfNecessary];
	}
}

- (void)textDidEndEditing:(NSNotification *)aNotification {
	if ([aNotification object] == textView) {
		//save last selection range for currentNote?
		//[currentNote setSelectedRange:[textView selectedRange]];

		//we need to set this here as we could return to searching before changing notes
		//and the next time the note would change would be when searching had triggered it
		//which would be too late
		[currentNote updateContentCacheCStringIfNecessary];
	}
}

- (NSMenu *)textView:(NSTextView *)view menu:(NSMenu *)menu forEvent:(NSEvent *)event atIndex:(NSUInteger)charIndex {
	NSInteger idx;
	if ((idx = [menu indexOfItemWithTarget:nil andAction:@selector(_removeLinkFromMenu:)]) > -1)
		[menu removeItemAtIndex:idx];
	if ((idx = [menu indexOfItemWithTarget:nil andAction:@selector(orderFrontLinkPanel:)]) > -1)
		[menu removeItemAtIndex:idx];
	return menu;
}

- (NSArray *)textView:(NSTextView *)aTextView completions:(NSArray *)words
  forPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger *)anIndex {

	NSArray *noteTitles = [notationController noteTitlesPrefixedByString:[[aTextView string] substringWithRange:charRange]
													 indexOfSelectedItem:anIndex];
	return noteTitles;
}


- (IBAction)fieldAction:(id)sender {

	[self createNoteIfNecessary];
	[window makeFirstResponder:textView];

}

- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)sender {

	if ([sender firstResponder] == textView) {

		NSUndoManager *undoMan = [self undoManagerForTextView:textView];
		if (undoMan)
			return undoMan;
	}
	return windowUndoManager;
}

- (NSUndoManager *)undoManagerForTextView:(NSTextView *)aTextView {
    if (aTextView == textView && currentNote)
		return [currentNote undoManager];

    return nil;
}

- (NoteObject*)createNoteIfNecessary {

    if (!currentNote) {
		//this assertion not yet valid until labels list changes notes list
		NSAssert([notesTableView numberOfSelectedRows] != 1, @"cannot create a note when one is already selected");

		[textView setTypingAttributes:[prefsController noteBodyAttributes]];
		[textView setFont:[prefsController noteBodyFont]];

		isCreatingANote = YES;
		NSString *title = [[field stringValue] length] ? [field stringValue] : NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
		NSAttributedString *attributedContents = [textView textStorage] ? [textView textStorage] : [[[NSAttributedString alloc] initWithString:@"" attributes:
																									 [prefsController noteBodyAttributes]] autorelease];
		NoteObject *note = [[[NoteObject alloc] initWithNoteBody:attributedContents title:title delegate:notationController
														  format:[notationController currentNoteStorageFormat] labels:nil] autorelease];
		[notationController addNewNote:note];

		isCreatingANote = NO;
		return note;
    }

    return currentNote;
}

- (void)restoreListStateUsingPreferences {
	//to be invoked after loading a notationcontroller

	NSString *searchString = [prefsController lastSearchString];
	if ([searchString length])
		[self searchForString:searchString];
	else
		[notationController refilterNotes];

	CFUUIDBytes bytes = [prefsController UUIDBytesOfLastSelectedNote];
	NSUInteger idx = [self revealNote:[notationController noteForUUIDBytes:&bytes] options:NVDoNotChangeScrollPosition];
	//scroll using saved scrollbar position
	[notesTableView scrollRowToVisible:NSNotFound == idx ? 0 : idx withVerticalOffset:[prefsController scrollOffsetOfLastSelectedNote]];
}

- (NSUInteger)revealNote:(NoteObject*)note options:(NSUInteger)opts {
	if (note) {
		NSUInteger selectedNoteIndex = [notationController indexInFilteredListForNoteIdenticalTo:note];

		if (selectedNoteIndex == NSNotFound) {
			NSLog(@"Note was not visible--showing all notes and trying again");
			[self cancelOperation:nil];

			selectedNoteIndex = [notationController indexInFilteredListForNoteIdenticalTo:note];
		}

		if (selectedNoteIndex != NSNotFound) {
			if (opts & NVDoNotChangeScrollPosition) { //select the note only
				[notesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selectedNoteIndex] byExtendingSelection:NO];
			} else {
				[notesTableView selectRowAndScroll:selectedNoteIndex];
			}
		}

		if (opts & NVEditNoteToReveal) {
			[window makeFirstResponder:textView];
		}
		if (opts & NVOrderFrontWindow) {
			//for external url-handling, often the app will already have been brought to the foreground
			if (![NSApp isActive]) {
				[NSApp activateIgnoringOtherApps:YES];
			}
			if (![window isKeyWindow])
				[window makeKeyAndOrderFront:nil];
		}
		return selectedNoteIndex;
	} else {
		[notesTableView deselectAll:self];
		return NSNotFound;
	}
}

- (void)notation:(NotationController*)notation revealNote:(NoteObject*)note options:(NSUInteger)opts {
	[self revealNote:note options:opts];
}

- (void)notation:(NotationController*)notation revealNotes:(NSArray*)notes {

	NSIndexSet *indexes = [notation indexesOfNotes:notes];
	if ([notes count] != [indexes count]) {
		[self cancelOperation:nil];

		indexes = [notation indexesOfNotes:notes];
	}
	if ([indexes count]) {
		[notesTableView selectRowIndexes:indexes byExtendingSelection:NO];
		[notesTableView scrollRowToVisible:[indexes firstIndex]];
	}
}

- (void)searchForString:(NSString*)string {

	if (string) {

		//problem: this won't work when the toolbar (and consequently the searchfield) is hidden;
		//and neither will the controlTextDidChange implementation
		[self _expandToolbar];

		[window makeFirstResponder:field];
		NSTextView* fieldEditor = (NSTextView*)[field currentEditor];
		NSRange fullRange = NSMakeRange(0, [[fieldEditor string] length]);
		if ([fieldEditor shouldChangeTextInRange:fullRange replacementString:string]) {
			[fieldEditor replaceCharactersInRange:fullRange withString:string];
			[fieldEditor didChangeText];
		} else {
			NSLog(@"I shouldn't change text?");
		}
	}
}

- (void)bookmarksController:(BookmarksController*)controller restoreNoteBookmark:(NoteBookmark*)aBookmark inBackground:(BOOL)inBG {
	if (aBookmark) {
		[self searchForString:[aBookmark searchString]];
		[self revealNote:[aBookmark noteObject] options:!inBG ? NVOrderFrontWindow : 0];
	}
}



- (void)splitView:(RBSplitView*)sender wasResizedFrom:(CGFloat)oldDimension to:(CGFloat)newDimension {
	if (sender == splitView) {
		[sender adjustSubviewsExcepting:[splitView subviewAtPosition:0]];
	}
}

- (BOOL)splitView:(RBSplitView*)sender shouldHandleEvent:(NSEvent*)theEvent inDivider:(NSUInteger)divider
	  betweenView:(RBSplitSubview*)leading andView:(RBSplitSubview*)trailing {
	//if upon the first mousedown, the top selected index is visible, snap to it when resizing
	[notesTableView noteFirstVisibleRow];

	if ([theEvent clickCount]>1) {
		BOOL wasVisible = [toolbar isVisible];
		if (wasVisible) {
			//pseudo-collapsing splitviews; the built-in collapsing makes it difficult to handle dragging to hide toolbar
			[[splitView subviewAtPosition:0] setDimension:1.0];
			[splitView adjustSubviews];
			[self _collapseToolbar];
		} else {
			[self _expandToolbar];
		}
		if (!wasVisible && [window firstResponder] == window) {
			[field selectText:sender];
		}
		return NO;
	}
	return YES;
}

//mail.app-like resizing behavior wrt item selections
- (void)willAdjustSubviews:(RBSplitView*)sender {
	//problem: don't do this if the horizontal splitview is being resized; in horizontal layout, only do this when resizing the window
	if (![prefsController horizontalLayout]) {
		[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
	}
}

- (NSSize)windowWillResize:(NSWindow *)window toSize:(NSSize)proposedFrameSize {
	if ([prefsController horizontalLayout]) {
		[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
	}
	return proposedFrameSize;
}

- (void)_expandToolbar {
	if (![toolbar isVisible]) {
		window.titleVisibility = NSWindowTitleHidden;
		[window setTitle:NSLocalizedString(@"Notation", @"App name")];
		if (currentNote)
			[field setStringValue:titleOfNote(currentNote)];
		[window toggleToolbarShown:nil];
		if (![splitView isDragging])
			[[splitView subviewAtPosition:0] setDimension:100.0];
		[[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ToolbarHidden"];
	}
	if ([[splitView subviewAtPosition:0] isCollapsed])
		[[splitView subviewAtPosition:0] expand];

}

- (void)_collapseToolbar {
	if ([toolbar isVisible]) {
		window.titleVisibility = NSWindowTitleVisible;
		if (currentNote)
			[window setTitle:titleOfNote(currentNote)];
		[window toggleToolbarShown:nil];
		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ToolbarHidden"];
	}
}

- (BOOL)splitView:(RBSplitView*)sender shouldResizeWindowForDivider:(NSUInteger)divider
	  betweenView:(RBSplitSubview*)leading andView:(RBSplitSubview*)trailing willGrow:(BOOL)grow {

	if ([sender isDragging]) {
		BOOL toolbarVisible = [toolbar isVisible];
		NSPoint mouse = [sender convertPoint:[[window currentEvent] locationInWindow] fromView:nil];

		if ((toolbarVisible && !grow && mouse.y < -28.0 && ![leading canShrink]) ||
			(!toolbarVisible && grow)) {
			BOOL wasVisible = toolbarVisible;
			if (toolbarVisible) {
				[self _collapseToolbar];
			} else {
				[self _expandToolbar];
			}

			if (!wasVisible && [window firstResponder] == window) {
				//if dualfield had first responder previously, it might need to be restored
				//if it had been removed from the view hierarchy due to hiding the toolbar
				[field selectText:sender];
			}
		}
	}

	return NO;
}

- (void)tableViewColumnDidResize:(NSNotification *)aNotification {
	NoteAttributeColumn *col = [[aNotification userInfo] objectForKey:@"NSTableColumn"];
	if ([[col identifier] isEqualToString:NoteTitleColumnString]) {
		[notationController regeneratePreviewsForColumn:col visibleFilteredRows:[notesTableView rowsInRect:[notesTableView visibleRect]] forceUpdate:NO];

	 	[NSObject cancelPreviousPerformRequestsWithTarget:notesTableView selector:@selector(reloadDataIfNotEditing) object:nil];
		[notesTableView performSelector:@selector(reloadDataIfNotEditing) withObject:nil afterDelay:0.0];
	}
}

- (NSRect)splitView:(RBSplitView*)sender willDrawDividerInRect:(NSRect)dividerRect betweenView:(RBSplitSubview*)leading
			andView:(RBSplitSubview*)trailing withProposedRect:(NSRect)imageRect {

	[dividerShader drawDividerInRect:dividerRect withDimpleRect:imageRect blendVertically:![prefsController horizontalLayout]];

	return NSZeroRect;
}

- (NSUInteger)splitView:(RBSplitView*)sender dividerForPoint:(NSPoint)point inSubview:(RBSplitSubview*)subview {
	if ([(AugmentedScrollView*)[notesTableView enclosingScrollView] shouldDragWithPoint:point sender:sender]) {
		return 0;       // [firstSplit position], which we assume to be zero
	}
	return NSNotFound;
}

- (BOOL)splitView:(RBSplitView*)sender canCollapse:(RBSplitSubview*)subview {
	if ([sender subviewAtPosition:0] == subview) {
		//this is the list view; let it collapse in horizontal layout when a note is being edited
		return [prefsController horizontalLayout] && currentNote != nil;
	}
	return NO;
}


//the notationcontroller must call notationListShouldChange: first
//if it's going to do something that could mess up the tableview's field eidtor
- (BOOL)notationListShouldChange:(NotationController*)someNotation {

	if (someNotation == notationController) {
		if ([notesTableView currentEditor])
			return NO;
	}

	return YES;
}

- (void)notationListMightChange:(NotationController*)someNotation {

	if (!isFilteringFromTyping) {
		if (someNotation == notationController) {
			//deal with one notation at a time

			if ([notesTableView numberOfSelectedRows] > 0) {
				NSIndexSet *indexSet = [notesTableView selectedRowIndexes];

				self.savedSelectedNotes = [someNotation notesAtIndexes:indexSet];
			}

			listUpdateViewCtx = [notesTableView viewingLocation];
		}
	}
}

- (void)notationListDidChange:(NotationController*)someNotation {

	if (someNotation == notationController) {
		//deal with one notation at a time

		[notesTableView reloadData];
		//[notesTableView noteNumberOfRowsChanged];

		if (!isFilteringFromTyping) {
			if (savedSelectedNotes) {
				NSIndexSet *indexes = [someNotation indexesOfNotes:savedSelectedNotes];
				self.savedSelectedNotes = nil;

				[notesTableView selectRowIndexes:indexes byExtendingSelection:NO];
			}

			[notesTableView setViewingLocation:listUpdateViewCtx];
		}
	}
}

- (void)titleUpdatedForNote:(NoteObject*)aNoteObject {
    if (aNoteObject == currentNote) {
		if ([toolbar isVisible]) {
			[field setStringValue:titleOfNote(currentNote)];
		} else {
			[window setTitle:titleOfNote(currentNote)];
		}
    }
	[[prefsController bookmarksController] updateBookmarksUI];
}

- (void)contentsUpdatedForNote:(NoteObject*)aNoteObject {
	if (aNoteObject == currentNote) {

		[[textView textStorage] setAttributedString:[aNoteObject contentString]];
	}
}

- (void)rowShouldUpdate:(NSInteger)affectedRow {
	NSRect rowRect = [notesTableView rectOfRow:affectedRow];
	NSRect visibleRect = [notesTableView visibleRect];

	if (NSContainsRect(visibleRect, rowRect) || NSIntersectsRect(visibleRect, rowRect)) {
		[notesTableView setNeedsDisplayInRect:rowRect];
	}
}

- (void)syncSessionsChangedVisibleStatus:(NSNotification*)aNotification {
	SyncSessionController *syncSessionController = [aNotification object];
	if ([syncSessionController hasErrors]) {
		[titleBarButton setStatusIconType:AlertIcon];
	} else if ([syncSessionController hasRunningSessions]) {
		[titleBarButton setStatusIconType:SynchronizingIcon];
	} else {
		[titleBarButton setStatusIconType: [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowSyncMenu"] ? DownArrowIcon : NoIcon ];
	}
}


- (IBAction)fixFileEncoding:(id)sender {
	if (currentNote) {
		[notationController synchronizeNoteChanges:nil];

		[[EncodingsManager sharedManager] showPanelForNote:currentNote];
	}
}

- (void)windowWillClose:(NSNotification *)aNotification {
	if ([prefsController quitWhenClosingWindow] && !externalEditingTerminationInProgress)
		[NSApp terminate:nil];
}

- (BOOL)windowShouldClose:(id)sender {
	(void)sender;
	return !externalEditingTerminationInProgress;
}

- (void)_finishSyncWait {
	//always post to next runloop to ensure that a sleep-delay response invocation, if one is also queued, runs before this one
	//if the app quits before the sleep-delay response posts, then obviously sleep will be delayed by quite a bit
	[self performSelector:@selector(syncWaitQuit:) withObject:nil afterDelay:0];
}

- (IBAction)syncWaitQuit:(id)sender {
	//need this variable to allow overriding the wait
	waitedForUncommittedChanges = YES;
	NSString *errMsg = [[notationController syncSessionController] changeCommittingErrorMessage];
	if ([errMsg length]) {
		NSAlert *syncAlert = [[[NSAlert alloc] init] autorelease];
		[syncAlert setMessageText:NSLocalizedString(@"Changes could not be uploaded.", nil)];
		[syncAlert setInformativeText:errMsg];
		[syncAlert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
		[syncAlert runModal];
	}

	[NSApp terminate:nil];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
	//if a sync session is still running, then wait for it to finish before sending terminatereply
	//otherwise, if there are unsynced notes to send, then push them right now and wait until session is no longer running
	//use waitForUncommitedChangesWithTarget:selector: and provide a callback to send NSTerminateNow

	InvocationRecorder *invRecorder = [InvocationRecorder invocationRecorder];
	[[invRecorder prepareWithInvocationTarget:self] _finishSyncWait];

	if (!waitedForUncommittedChanges &&
		[[notationController syncSessionController] waitForUncommitedChangesWithInvocation:[invRecorder invocation]]) {

		[[NSApp windows] makeObjectsPerformSelector:@selector(orderOut:) withObject:nil];
		[syncWaitPanel center];
		[syncWaitPanel makeKeyAndOrderFront:nil];
		[syncWaitSpinner startAnimation:nil];
		//use NSTerminateCancel instead of NSTerminateLater because we need the runloop functioning in order to receive start/stop sync notifications
		return NSTerminateCancel;
	}
	ExternalEditingSession *editor = [ExternalEditingSession sharedExternalEditingSession];
	/* Opening a separately stored note edits its real file and creates no scratch
	 * session. Only temporary handoffs need the warning and final drain below. */
	if ([editor activeScratchEditingSessionCount]) {
		if (externalEditingTerminationInProgress) return NSTerminateLater;
		externalEditingTerminationInProgress = YES;
		[editor beginScratchEditingSuspension];
		[self _confirmQuittingExternalEditingWithCompletionHandler:^(BOOL shouldQuit) {
			if (!shouldQuit) {
				externalEditingTerminationInProgress = NO;
				[self _restoreWindowAfterCanceledTermination];
				[editor endScratchEditingSuspension];
				[sender replyToApplicationShouldTerminate:NO];
				return;
			}
			[editor finishAllScratchEditingSessionsWithCompletionHandler:^(BOOL success) {
				externalEditingTerminationInProgress = NO;
				if (!success) {
					[self _restoreWindowAfterCanceledTermination];
					[self externalEditingSessionTeardownFailed];
				}
				[editor endScratchEditingSuspension];
				[sender replyToApplicationShouldTerminate:success];
			}];
		}];
		return NSTerminateLater;
	}
	return NSTerminateNow;
}

- (void)externalEditingSessionTeardownFailed {
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"External editing could not be finished.", nil)];
	[alert setInformativeText:NSLocalizedString(
		@"The operation was canceled. The temporary file and its external-editing session remain available; save again and retry.", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
	[alert setAlertStyle:NSAlertStyleCritical];
	if (window) [alert beginSheetModalForWindow:window completionHandler:nil];
	else [alert runModal];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
	if (notationController) {
		//only save the state if the notation instance has actually loaded; i.e., don't save last-selected-note if we quit from a PW dialog
		BOOL wasAutomatic = NO;
		NSRange currentRange = [textView selectedRangeWasAutomatic:&wasAutomatic];
		if (!wasAutomatic) [currentNote setSelectedRange:currentRange];

		[currentNote updateContentCacheCStringIfNecessary];

		[prefsController setLastSearchString:[self fieldSearchString] selectedNote:currentNote
					scrollOffsetForTableView:notesTableView sender:self];

		[prefsController saveCurrentBookmarksFromSender:self];
	}

	[[NSApp windows] makeObjectsPerformSelector:@selector(close)];
	[notationController stopFileNotifications];

	//wait for syncing to finish, showing a progress bar

    if ([notationController flushAllNoteChanges])
		[notationController closeJournal];
	else
		NSLog(@"Could not flush database, so not removing journal");

    [prefsController synchronize];
}

- (void)dealloc {
	[tagEditor release];
	[savedSelectedNotes release];
	[windowUndoManager release];
	[dividerShader release];
	[sparkleController release];

	[super dealloc];
}

- (IBAction)showPreferencesWindow:(id)sender {
	[prefsWindowController showWindow:sender];
}

- (IBAction)toggleNVActivation:(id)sender {

	if ([NSApp isActive] && [window isMainWindow]) {
		[NSApp hide:sender];
		return;
	}
	[self bringFocusToControlField:sender];
}

- (IBAction)bringFocusToControlField:(id)sender {
	[self _expandToolbar];

	[field selectText:sender];

	if (![NSApp isActive]) {
		[NSApp activateIgnoringOtherApps:YES];
	}
	if (![window isMainWindow]) [window makeKeyAndOrderFront:sender];

	[self setEmptyViewState:currentNote == nil];
}

- (NSWindow*)window {
	return window;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)application {
	return YES;
}

@end
