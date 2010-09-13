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


#import "AppController.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "AlienNoteImporter.h"
#import "NotationPrefs.h"
#import "PrefsWindowController.h"
#import "NoteAttributeColumn.h"
#import "NotationSyncServiceManager.h"
#import "NotationDirectoryManager.h"
#import "NSString_NV.h"
#import "NSCollection_utils.h"
#import "AttributedPlainText.h"
#import "EncodingsManager.h"
#import "ExporterManager.h"
#import "NSData_transformations.h"
#import "BufferUtils.h"
#import "LinkingEditor.h"
#import "EmptyView.h"
#import "DualField.h"
#import "TitlebarButton.h"
#import "RBSplitView/RBSplitView.h"
#import "BookmarksController.h"
#import "SyncSessionController.h"
#import "DeletionManager.h"
#import "MultiplePageView.h"
#import "InvocationRecorder.h"
#import "URLGetter.h"
#import "LinearDividerShader.h"
#import <WebKit/WebArchive.h>
#include <Carbon/Carbon.h>

@implementation AppController

//an instance of this class is designated in the nib as the delegate of the window, nstextfield and two nstextviews

- (id)init {
    if ([super init]) {
		
		windowUndoManager = [[NSUndoManager alloc] init];

		// Setup URL Handling
		NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
		[appleEventManager setEventHandler:self andSelector:@selector(handleGetURLEvent:withReplyEvent:) forEventClass:kInternetEventClass andEventID:kAEGetURL];	
		
		dividerShader = [[LinearDividerShader alloc] initWithStartColor:[NSColor colorWithCalibratedWhite:0.988 alpha:1.0] 
															   endColor:[NSColor colorWithCalibratedWhite:0.875 alpha:1.0]];
		
		isCreatingANote = isFilteringFromTyping = typedStringIsCached = NO;
		typedString = @"";
		
    }
    return self;
}

- (void)awakeFromNib {
	prefsController = [GlobalPrefs defaultPrefs];
	
	NSView *dualSV = [field superview];
	dualFieldItem = [[NSToolbarItem alloc] initWithItemIdentifier:@"DualField"];
	//[[dualSV superview] setFrameSize:NSMakeSize([[dualSV superview] frame].size.width, [[dualSV superview] frame].size.height -1)];
	[dualFieldItem setView:dualSV];
	[dualFieldItem setMaxSize:NSMakeSize(FLT_MAX, [dualSV frame].size.height)];
	[dualFieldItem setMinSize:NSMakeSize(50.0f, [dualSV frame].size.height)];
    [dualFieldItem setLabel:@"Search or Create"];
	
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

	[NSApp setDelegate:self];
	[notesTableView setDelegate:self];
	[window setDelegate:self];
	[field setDelegate:self];
	[textView setDelegate:self];
	[splitView setDelegate:self];
	
	//set up temporary FastListDataSource containing false visible notes
		
	//this will not make a difference
	[window useOptimizedDrawing:YES];
	

	//[window makeKeyAndOrderFront:self];
	//[self setEmptyViewState:YES];
	
	outletObjectAwoke(self);
}

//really need make AppController a subclass of NSWindowController and stick this junk in windowDidLoad
- (void)setupViewsAfterAppAwakened {
	static BOOL awakenedViews = NO;
	if (!awakenedViews) {
		//NSLog(@"all (hopefully relevant) views awakend!");		
		[splitView restoreState:YES];
		
		[splitSubview addSubview:editorStatusView positioned:NSWindowAbove relativeTo:splitSubview];
		[editorStatusView setFrame:[[textView enclosingScrollView] frame]];
		
		[notesTableView restoreColumns];
		
		[field setNextKeyView:textView];
		[textView setNextKeyView:field];
		[window setAutorecalculatesKeyViewLoop:NO];
				
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
	[prefsController registerAppActivationKeystrokeWithTarget:self selector:@selector(toggleNVActivation:)];
	[notationController checkIfNotationIsTrashed];
	
	//connect sparkle programmatically to avoid loading its framework at nib awake;
	
	if (!NSClassFromString(@"SUUpdater")) {
		NSString *frameworkPath = [[[NSBundle bundleForClass:[self class]] privateFrameworksPath] stringByAppendingPathComponent:@"Sparkle.framework"];
		if ([[NSBundle bundleWithPath:frameworkPath] load]) {
			id updater = [NSClassFromString(@"SUUpdater") performSelector:@selector(sharedUpdater)];
			[sparkleUpdateItem setTarget:updater];
			[sparkleUpdateItem setAction:@selector(checkForUpdates:)];
			if (![[prefsController notationPrefs] firstTimeUsed]) {
				//don't do anything automatically on the first launch; afterwards, check every 4 days, as specified in Info.plist
				SEL checksSEL = @selector(setAutomaticallyChecksForUpdates:);
				[updater methodForSelector:checksSEL](updater, checksSEL, YES);
			}
		} else {
			NSLog(@"Could not load %@!", frameworkPath);
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
	NSData *aliasData = [prefsController aliasDataForDefaultDirectory];
	
	NSString *subMessage = @"";
	
	if (aliasData) {
	    newNotation = [[NotationController alloc] initWithAliasData:aliasData error:&err];
	    subMessage = NSLocalizedString(@"Please choose a different folder in which to store your notes.",nil);
	} else {
	    newNotation = [[NotationController alloc] initWithDefaultDirectoryReturningError:&err];
	    subMessage = NSLocalizedString(@"Please choose a folder in which your notes will be stored.",nil);
	}
	//no need to display an alert if the error wasn't real
	if (err == kPassCanceledErr)
		goto showOpenPanel;
	
	NSString *location = (aliasData ? [NSString pathCopiedFromAliasData:aliasData] : NSLocalizedString(@"your Application Support directory",nil));
	if (!location) { //fscopyaliasinfo sucks
		FSRef locationRef;
		if ([aliasData fsRefAsAlias:&locationRef] && LSCopyDisplayNameForRef(&locationRef, (CFStringRef*)&location) == noErr) {
			[location autorelease];
		} else {
			location = NSLocalizedString(@"its current location",nil);
		}
	}
	
	while (!newNotation) {
	    location = [location stringByAbbreviatingWithTildeInPath];
	    NSString *reason = [NSString reasonStringFromCarbonFSError:err];
		
	    if (NSRunAlertPanel([NSString stringWithFormat:NSLocalizedString(@"Unable to initialize notes database in \n%@ because %@.",nil), location, reason], 
							subMessage, NSLocalizedString(@"Choose another folder",nil),NSLocalizedString(@"Quit",nil),NULL) == NSAlertDefaultReturn) {
			//show nsopenpanel, defaulting to current default notes dir
			FSRef notesDirectoryRef;
		showOpenPanel:
			if (![prefsWindowController getNewNotesRefFromOpenPanel:&notesDirectoryRef returnedPath:&location]) {
				//they cancelled the open panel, or it was unable to get the path/FSRef of the file
				goto terminateApp;
			} else if ((newNotation = [[NotationController alloc] initWithDirectoryRef:&notesDirectoryRef error:&err])) {
				//have to make sure alias data is saved from setNotationController
				[newNotation setAliasNeedsUpdating:YES];
				break;
			}
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
	
	if (pathsToOpenOnLaunch) {
		[notationController openFiles:pathsToOpenOnLaunch];
		[pathsToOpenOnLaunch release];
		pathsToOpenOnLaunch = nil;
	}
	
	if (URLToSearchOnLaunch) {
		[self searchForString:[[URLToSearchOnLaunch substringFromIndex:5] stringByReplacingPercentEscapes]];
		[URLToSearchOnLaunch release];
		URLToSearchOnLaunch = nil;
	}
	
	//tell us..
	[prefsController registerWithTarget:self forChangesInSettings:
	 @selector(setAliasDataForDefaultDirectory:sender:),  //when someone wants to load a new database
	 @selector(setSortedTableColumnKey:reversed:sender:),  //when sorting prefs changed
	 @selector(setNoteBodyFont:sender:),  //when to tell notationcontroller to restyle its notes
	 @selector(setTableFontSize:sender:),  //when to tell notationcontroller to regenerate the (now potentially too-short) note-body previews
	 @selector(setTableColumnsShowPreview:sender:),  //when to tell notationcontroller to generate or disable note-body previews
	 @selector(setConfirmNoteDeletion:sender:),nil];  //whether "delete note" should have an ellipsis
	
	[self performSelector:@selector(runDelayedUIActionsAfterLaunch) withObject:nil afterDelay:0.0];
			
	return;
terminateApp:
	[NSApp terminate:self];
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	
	NSString *fullURL = [[[event paramDescriptorForKeyword:keyDirectObject] stringValue] retain];
	
	if (notationController) {
		[self searchForString:[[fullURL substringFromIndex:5] stringByReplacingPercentEscapes]];
	} else {
		URLToSearchOnLaunch = fullURL;
	}
}

- (void)setNotationController:(NotationController*)newNotation {
	
    if (newNotation) {
		if (notationController) {
			[notationController stopSyncServices];
			[[NSNotificationCenter defaultCenter] removeObserver:self name:SyncSessionsChangedVisibleStatusNotification 
														  object:[notationController syncSessionController]];
			[notationController stopFileNotifications];
			if ([notationController flushAllNoteChanges])
				[notationController closeJournal];
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
		[notationController setDelegate:self];
		
		//allow resolution of UUIDs to NoteObjects from saved searches
		[[prefsController bookmarksController] setDataSource:notationController];
		
		//update the list using the new notation and saved settings
		[self restoreListStateUsingPreferences];
		
		//window's undomanager could be referencing actions from the old notation object
		[[window undoManager] removeAllActions];
		[notationController setUndoManager:[window undoManager]];
		[[DeletionManager sharedManager] setDelegate:notationController];
		
		if ([notationController aliasNeedsUpdating]) {
			[prefsController setAliasDataForDefaultDirectory:[notationController aliasDataForNoteDirectory] sender:self];
		}
		if ([[GlobalPrefs defaultPrefs] tableColumnsShowPreview]) {
			[notationController regeneratePreviewsForColumn:[notesTableView noteAttributeColumnForIdentifier:NoteTitleColumnString] 
										visibleFilteredRows:[notesTableView rowsInRect:[notesTableView visibleRect]] forceUpdate:YES];
			[notesTableView setNeedsDisplay:YES];
		}
		[titleBarButton setMenu:[[notationController syncSessionController] syncStatusMenu]];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncSessionsChangedVisibleStatus:) 
													 name:SyncSessionsChangedVisibleStatusNotification 
												   object:[notationController syncSessionController]]; 
		[notationController performSelector:@selector(startSyncServices) withObject:nil afterDelay:0.0];
		
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
	return [itemIdentifier isEqualToString:@"DualField"] ? dualFieldItem : nil;
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar*)theToolbar {
	return [self toolbarDefaultItemIdentifiers:theToolbar];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)theToolbar {
	return [NSArray arrayWithObject:@"DualField"];
}


- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
	SEL selector = [menuItem action];
	int numberSelected = [notesTableView numberOfSelectedRows];
	
	if (selector == @selector(printNote:) || 
		selector == @selector(deleteNote:) ||
		selector == @selector(exportNote:) || 
		selector == @selector(tagNote:)) {
		
		return (numberSelected > 0);
		
	} else if (selector == @selector(renameNote:)) {
		
		return (numberSelected == 1);
	} else if (selector == @selector(fixFileEncoding:)) {
		
		return (currentNote != nil && storageFormatOfNote(currentNote) == PlainTextFormat && ![currentNote contentsWere7Bit]);
	}
	
	return YES;
}

/*
 - (void)menuNeedsUpdate:(NSMenu *)menu {
 NSLog(@"mama needs update: %@", [menu title]);
 
 NSArray *selectedNotes = [notationController notesAtIndexes:[notesTableView selectedRowIndexes]];
 [selectedNotes setURLsInNotesForMenu:menu];
 }*/

- (void)updateNoteMenus {
	NSMenu *notesMenu = [[[NSApp mainMenu] itemWithTag:NOTES_MENU_ID] submenu];
	
	int menuIndex = [notesMenu indexOfItemWithTarget:self andAction:@selector(deleteNote:)];
	NSMenuItem *deleteItem = nil;
	if (menuIndex > -1 && (deleteItem = [notesMenu itemAtIndex:menuIndex]))	{
		NSString *trailingQualifier = [prefsController confirmNoteDeletion] ? NSLocalizedString(@"...", @"ellipsis character") : @"";
		[deleteItem setTitle:[NSString stringWithFormat:@"%@%@", 
							  NSLocalizedString(@"Delete", nil), trailingQualifier]];
	}
	
	NSMenu *viewMenu = [[[NSApp mainMenu] itemWithTitle:@"View"] submenu];
	menuIndex = [viewMenu indexOfItemWithTarget:notesTableView andAction:@selector(toggleNoteBodyPreviews:)];
	NSMenuItem *bodyPreviewItem = nil;
	if (menuIndex > -1 && (bodyPreviewItem = [viewMenu itemAtIndex:menuIndex])) {
		[bodyPreviewItem setTitle: [prefsController tableColumnsShowPreview] ? 
		 NSLocalizedString(@"Hide Note Previews in Title", @"menu item in the View menu to turn off note-body previews in the Title column") : 
		 NSLocalizedString(@"Show Note Previews in Title", @"menu item in the View menu to turn on note-body previews in the Title column")];
	}
}

- (void)createFromSelection:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
	if (!notationController || ![self addNotesFromPasteboard:pboard]) {
		*error = NSLocalizedString(@"Error: Couldn't create a note from the selection.", @"error message to set during a Service call when adding a note failed");
	}
}

- (BOOL)addNotesFromPasteboard:(NSPasteboard*)pasteboard {
	
	NSArray *types = [pasteboard types];
	NSMutableAttributedString *newString = nil;
	NoteObject *note = nil;
	NSData *data = nil;
		
	if ([types containsObject:NSFilenamesPboardType]) {
		NSArray *files = [pasteboard propertyListForType:NSFilenamesPboardType];
		if ([files isKindOfClass:[NSArray class]]) {
			if ([notationController openFiles:files]) return YES;
		}
	}
	
	NSString *sourceIdentiferString = nil;
	
	//webkit URL!
	if ([types containsObject:WebArchivePboardType]) {
		sourceIdentiferString = [[pasteboard dataForType:WebArchivePboardType] pathURLFromWebArchive];
		//gecko URL!
	} else if ([types containsObject:[NSString customPasteboardTypeOfCode:0x4D5A0003]]) {
		//lazilly use syntheticTitle to get first line, even though that's not how our API is documented
		sourceIdentiferString = [[pasteboard stringForType:[NSString customPasteboardTypeOfCode:0x4D5A0003]] syntheticTitleAndTrimmedBody:NULL];
		unichar nullChar = 0x0;
		sourceIdentiferString = [sourceIdentiferString stringByReplacingOccurrencesOfString:
								 [NSString stringWithCharacters:&nullChar length:1] withString:@""];
	}
	
	if ([types containsObject:NSURLPboardType]) {
		NSURL *url = [NSURL URLFromPasteboard:pasteboard];
		
		NSString *potentialURLString = [types containsObject:NSStringPboardType] ? [pasteboard stringForType:NSStringPboardType] : nil;
		if (potentialURLString && [[url absoluteString] isEqualToString:potentialURLString]) {
			//only begin downloading if we know that there's no other useful string data
			//because we've already checked NSFilenamesPboardType
			
			if ([[url scheme] caseInsensitiveCompare:@"http"] == NSOrderedSame || 
				[[url scheme] caseInsensitiveCompare:@"https"] == NSOrderedSame ||
				[[url scheme] caseInsensitiveCompare:@"ftp"] == NSOrderedSame) {
				NSString *linkTitleType = [NSString customPasteboardTypeOfCode:0x75726C6E];
				NSString *linkTitle = [types containsObject:linkTitleType] ? [[pasteboard stringForType:linkTitleType] syntheticTitleAndTrimmedBody:NULL] : nil;
				if (!linkTitle) {
					//try urld instead of urln
					linkTitleType = [NSString customPasteboardTypeOfCode:0x75726C64];
					linkTitle = [types containsObject:linkTitleType] ? [[pasteboard stringForType:linkTitleType] syntheticTitleAndTrimmedBody:NULL] : nil;
				}
				[[[[AlienNoteImporter alloc] init] autorelease] importURLInBackground:url linkTitle:linkTitle receptionDelegate:self];
				return YES;
			}
		}		
	}
	
	//safari on 10.5 does not seem to provide a plain-text equivalent, so we must be able to dumb-down RTF data as well
	//should fall-back to plain text if 1) user doesn't want styles and 2) plain text is actually available
	BOOL shallUsePlainTextFallback = [types containsObject:NSStringPboardType] && ![prefsController pastePreservesStyle];
	BOOL hasRTFData = NO;
	
	if ([types containsObject:NVPTFPboardType]) {
		if ((data = [pasteboard dataForType:NVPTFPboardType]))
			newString = [[NSMutableAttributedString alloc] initWithRTF:data documentAttributes:NULL];
		
	} else if ([types containsObject:NSRTFPboardType] && !shallUsePlainTextFallback) {
		if ((data = [pasteboard dataForType:NSRTFPboardType]))
			newString = [[NSMutableAttributedString alloc] initWithRTF:data documentAttributes:NULL];
		hasRTFData = YES;
	} else if ([types containsObject:NSRTFDPboardType] && !shallUsePlainTextFallback) {
		if ((data = [pasteboard dataForType:NSRTFDPboardType]))
			newString = [[NSMutableAttributedString alloc] initWithRTFD:data documentAttributes:NULL];
		hasRTFData = YES;
	} else if ([types containsObject:WebArchivePboardType] && !shallUsePlainTextFallback) {
		if ((data = [pasteboard dataForType:WebArchivePboardType])) {
			//set a timeout because -[NSHTMLReader _loadUsingWebKit] can sometimes hang
			newString = [[NSMutableAttributedString alloc] initWithData:data options:[NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:10.0] forKey:NSTimeoutDocumentOption] 
													 documentAttributes:NULL error:NULL];
		}
		hasRTFData = YES;
	} else if (([types containsObject:NSStringPboardType])) {
		
		NSString *pboardString = [pasteboard stringForType:NSStringPboardType];
		if (pboardString) newString = [[NSMutableAttributedString alloc] initWithString:pboardString];
	}
	
	[newString autorelease];
	if ([newString length] > 0) {
		[newString removeAttachments];
		
		if (hasRTFData && ![prefsController pastePreservesStyle]) //fallback scenario
			newString = [[[NSMutableAttributedString alloc] initWithString:[newString string]] autorelease];
		
		NSString *noteTitle = [newString trimLeadingSyntheticTitle];
		if ([sourceIdentiferString length] > 0) {
			//add the URL or wherever it was that this piece of text came from
			[newString prefixWithSourceString:sourceIdentiferString];
		}
		[newString santizeForeignStylesForImporting];
		note = [notationController addNote:newString withTitle:noteTitle];
		return note != nil;
	}
	
	return NO;
}

- (IBAction)renameNote:(id)sender {
    //edit the first selected note	
	[notesTableView editRowAtColumnWithIdentifier:NoteTitleColumnString];
}

- (void)deleteSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void  *)contextInfo {
	id retainedDeleteObj = (id)contextInfo;
	
	if (returnCode == NSAlertDefaultReturn) {
		//delete! nil-msgsnd-checking
		
		//ensure that there are no pending edits in the tableview, 
		//lest editing end with the same field editor and a different selected note
		//resulting in the renaming of notes in adjacent rows
		[notesTableView abortEditing];
		
		if ([retainedDeleteObj isKindOfClass:[NSArray class]]) {
			[notationController removeNotes:retainedDeleteObj];
		} else if ([retainedDeleteObj isKindOfClass:[NoteObject class]]) {
			[notationController removeNote:retainedDeleteObj];
		}
	}
	[retainedDeleteObj release];
}


- (IBAction)deleteNote:(id)sender {
		
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	if ([indexes count] > 0) {
		id deleteObj = [indexes count] > 1 ? (id)([notationController notesAtIndexes:indexes]) : (id)([notationController noteObjectAtFilteredIndex:[indexes firstIndex]]);
		
		if ([prefsController confirmNoteDeletion]) {
			[deleteObj retain];
			NSString *warningSingleFormatString = NSLocalizedString(@"Delete the note titled quotemark%@quotemark?", @"alert title when asked to delete a note");
			NSString *warningMultipleFormatString = NSLocalizedString(@"Delete %d notes?", @"alert title when asked to delete multiple notes");
			NSString *warnString = currentNote ? [NSString stringWithFormat:warningSingleFormatString, titleOfNote(currentNote)] : 
			[NSString stringWithFormat:warningMultipleFormatString, [indexes count]];
			NSBeginAlertSheet(warnString, NSLocalizedString(@"Delete", @"name of delete button"), NSLocalizedString(@"Cancel", @"name of cancel button"), 
							  nil, window, self, @selector(deleteSheetDidEnd:returnCode:contextInfo:), NULL, (void*)deleteObj, 
							  NSLocalizedString(@"Press Command-Z to undo this action later.", @"informational delete-this-note? text"));
		} else {
			//just delete the notes outright			
			[notationController performSelector:[indexes count] > 1 ? @selector(removeNotes:) : @selector(removeNote:) withObject:deleteObj];
		}
	}
}

- (IBAction)exportNote:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	NSArray *notes = [notationController notesAtIndexes:indexes];
	
	[notationController synchronizeNoteChanges:nil];
	[[ExporterManager sharedManager] exportNotes:notes forWindow:window];
}

- (IBAction)printNote:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	[MultiplePageView printNotes:[notationController notesAtIndexes:indexes] forWindow:window];
}

- (IBAction)tagNote:(id)sender {
	//if single note, add the tag column if necessary and then begin editing
	
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	if ([indexes count] > 1) {
		//show dialog for multiple notes, add or remove tags from them all using a dialog
		//tags to remove is constituted by a union of all selected notes' tags
		NSLog(@"multiple rows");	
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
    
    if ([selectorString isEqualToString:SEL_STR(setAliasDataForDefaultDirectory:sender:)]) {
		//defaults changed for the database location -- load the new one!
		
		OSStatus err = noErr;
		NotationController *newNotation = nil;
		NSData *newData = [prefsController aliasDataForDefaultDirectory];
		if (newData) {
			if ((newNotation = [[NotationController alloc] initWithAliasData:newData error:&err])) {
				[self setNotationController:newNotation];
				[newNotation release];
				
			} else {
				
				//set alias data back
				NSData *oldData = [notationController aliasDataForNoteDirectory];
				[prefsController setAliasDataForDefaultDirectory:oldData sender:self];
				
				//display alert with err--could not set notation directory 
				NSString *location = [[NSString pathCopiedFromAliasData:newData] stringByAbbreviatingWithTildeInPath];
				NSString *oldLocation = [[NSString pathCopiedFromAliasData:oldData] stringByAbbreviatingWithTildeInPath]; 
				NSString *reason = [NSString reasonStringFromCarbonFSError:err];
				NSRunAlertPanel([NSString stringWithFormat:NSLocalizedString(@"Unable to initialize notes database in \n%@ because %@.",nil), location, reason], 
								[NSString stringWithFormat:NSLocalizedString(@"Reverting to current location of %@.",nil), oldLocation], 
								NSLocalizedString(@"OK",nil), NULL, NULL);
			}
		}
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
	} else if ([selectorString isEqualToString:SEL_STR(setTableFontSize:sender:)] || [selectorString isEqualToString:SEL_STR(setTableColumnsShowPreview:sender:)]) {
		
		[notesTableView updateTitleDereferencorState];
		[notationController regeneratePreviewsForColumn:[notesTableView noteAttributeColumnForIdentifier:NoteTitleColumnString]	
									visibleFilteredRows:[notesTableView rowsInRect:[notesTableView visibleRect]] forceUpdate:YES];
				
		if ([selectorString isEqualToString:SEL_STR(setTableColumnsShowPreview:sender:)]) [self updateNoteMenus];
		
		[notesTableView performSelector:@selector(reloadData) withObject:nil afterDelay:0];
		
	} else if ([selectorString isEqualToString:SEL_STR(setConfirmNoteDeletion:sender:)]) {
		[self updateNoteMenus];
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
			[[NSWorkspace sharedWorkspace] openURLs:[NSArray arrayWithObject:[NSURL fileURLWithPath:path]] withAppBundleIdentifier:@"com.apple.TextEdit" 
											options:NSWorkspaceLaunchDefault additionalEventParamDescriptor:nil launchIdentifiers:NULL];
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
		[notationController openFiles:filenames];
	else
		pathsToOpenOnLaunch = [filenames mutableCopyWithZone:nil];
	
	[NSApp replyToOpenOrPrint:[filenames count] ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
}

- (void)applicationDidBecomeActive:(NSNotification *)aNotification {
	[notationController checkJournalExistence];
	
    if ([notationController currentNoteStorageFormat] != SingleDatabaseFormat)
		[notationController performSelector:@selector(synchronizeNotesFromDirectory) withObject:nil afterDelay:0.0];
	
	if ([[prefsController notationPrefs] secureTextEntry]) {
		EnableSecureEventInput();
	}
	
	[notationController updateDateStringsIfNecessary];
}

- (void)applicationWillResignActive:(NSNotification *)aNotification {
	if ([[prefsController notationPrefs] secureTextEntry]) {
		DisableSecureEventInput();
	}
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
			
			unsigned int strLen = [[aTextView string] length];
			if (!singleSelection && [aTextView selectedRange].length != strLen) {
				[aTextView setSelectedRange:NSMakeRange(0, strLen)];
			}
			
			return YES;
		}
		
		if ((command == @selector(insertTab:) || command == @selector(insertTabIgnoringFieldEditor:))) {
			//[self setEmptyViewState:NO];
			
			if (![[aTextView string] length] || [textView isHidden]) return YES;
			
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
			if ([event modifierFlags] & NSControlKeyMask) {
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

- (NSString*)fieldSearchString {
	NSString *typed = [self typedString];
	if (typed) return typed;
	
	if (!currentNote) return [field stringValue];
	
	return nil;
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
			

			NSUInteger preferredNoteIndex = [notationController preferredSelectedNoteIndex];
			
			//lastLengthReplaced depends on textView:shouldChangeTextInRange:replacementString: being sent before controlTextDidChange: runs			
			if ([prefsController autoCompleteSearches] && preferredNoteIndex != NSNotFound && 
				([field lastLengthReplaced] > 0 /*|| [notationController preferredSelectedNoteMatchesSearchString]*/)) {
				
				[notesTableView selectRowAndScroll:preferredNoteIndex];
				
				if (didFilter) { 
					//current selection may be at the same row, but note at that row may have changed
					[self displayContentsForNoteAtIndex:preferredNoteIndex];
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
	}
}

- (void)tableViewSelectionIsChanging:(NSNotification *)aNotification {
	
	BOOL allowMultipleSelection = NO;
	NSEvent *event = [window currentEvent];
    
	NSEventType type = [event type];
	//do not allow drag-selections unless a modifier is pressed
	if (type == NSLeftMouseDragged || type == NSLeftMouseDown) {
		unsigned flags = [event modifierFlags];
		if ((flags & NSShiftKeyMask) || (flags & NSCommandKeyMask)) {
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
	if (type != NSKeyDown && type != NSKeyUp) {
		[self performSelector:@selector(setTableAllowsMultipleSelection) withObject:nil afterDelay:0];
	}
	
	[self processChangedSelectionForTable:[aNotification object]];
}

- (void)processChangedSelectionForTable:(NSTableView*)table {
	int selectedRow = [table selectedRow];
	int numberSelected = [table numberOfSelectedRows];
	
	NSTextView *fieldEditor = (NSTextView*)[field currentEditor];
	
	if (table == (NSTableView*)notesTableView) {
		
		if (selectedRow > -1 && numberSelected == 1) {
			//if it is uncached, cache the typed string only if we are selecting a note
			
			[self cacheTypedStringIfNecessary:[fieldEditor string]];
			
			//add snapback-button here?
			if (!isFilteringFromTyping && !isCreatingANote)
				[field setSnapbackString:typedString];
			
			if ([self displayContentsForNoteAtIndex:selectedRow]) {
				
				[[field cell] setShowsClearButton:YES];
				
				//there doesn't seem to be any situation in which a note will be selected
				//while the user is typing and auto-completion is disabled, so should be OK

				if (!isFilteringFromTyping) {
					if ([toolbar isVisible]) {
						if (fieldEditor) {
							//the field editor has focus--select text, too
							[fieldEditor setString:titleOfNote(currentNote)];
							unsigned int strLen = [titleOfNote(currentNote) length];
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
	[textView setHidden:enable];
	[editorStatusView setHidden:!enable];
	
	if (enable) {
		[editorStatusView setLabelStatus:[notesTableView numberOfSelectedRows]];
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
			firstFoundTermRange = [textView highlightTermsTemporarilyReturningFirstRange:typedString];
		
		//if there was nothing selected, select the first found range
		if (!noteSelectionRange.length && firstFoundTermRange.location != NSNotFound)
			noteSelectionRange = firstFoundTermRange;
		
		//select and scroll
		[textView setAutomaticallySelectedRange:noteSelectionRange];
		[textView scrollRangeToVisible:noteSelectionRange];
		
		//NSString *words = noteIndex != [notationController preferredSelectedNoteIndex] ? typedString : nil;
		//[textView setFutureSelectionRange:noteSelectionRange highlightingWords:words];
		
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

- (IBAction)fieldAction:(id)sender {
	
	[self createNoteIfNecessary];
	[window makeFirstResponder:textView];
	
}

- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)sender {
	
	if ([sender firstResponder] == textView) {
		if ((floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_3) && currentNote) {
			NSLog(@"windowWillReturnUndoManager should not be called when textView is first responder on Tiger or higher");
		}
		
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
		NoteObject *newNote = [notationController addNote:[textView textStorage] withTitle:[field stringValue]];
		isCreatingANote = NO;
		return newNote;
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
	NSUInteger idx = [self _revealNote:[notationController noteForUUIDBytes:&bytes] options:NVDoNotChangeScrollPosition];
	//scroll using saved scrollbar position
	[notesTableView scrollRowToVisible:NSNotFound == idx ? 0 : idx withVerticalOffset:[prefsController scrollOffsetOfLastSelectedNote]];
}

- (NSUInteger)_revealNote:(NoteObject*)note options:(NSUInteger)opts {
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
		
		if (opts & NVEditNoteToReveal) [window makeFirstResponder:textView];
		if ((opts & NVOrderFrontWindow) && ![window isKeyWindow]) {
			[window makeKeyAndOrderFront:nil];
		}
		return selectedNoteIndex;
	} else {
		[notesTableView deselectAll:self];
		return NSNotFound;
	}
}

- (void)notation:(NotationController*)notation revealNote:(NoteObject*)note options:(NSUInteger)opts {
	[self _revealNote:note options:opts];
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
		[self _revealNote:[aBookmark noteObject] options:!inBG ? NVOrderFrontWindow : 0];
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
	return YES;
}

//mail.app-like resizing behavior wrt item selections
- (void)willAdjustSubviews:(RBSplitView*)sender {
	[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
}

- (void)_expandToolbar {
	if (![toolbar isVisible]) {
		[window setTitle:@"Notation"];
		if (currentNote)
			[field setStringValue:titleOfNote(currentNote)];
		[window toggleToolbarShown:nil];
		if (![splitView isDragging])
			[[splitView subviewAtPosition:0] setDimension:100.0];
		[[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ToolbarHidden"];
	}
}

- (void)_collapseToolbar {
	if ([toolbar isVisible]) {
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
	if (dereferencingFunction(col) == tableTitleOfNote || dereferencingFunction(col) == properlyHighlightingTableTitleOfNote) {
		[notationController regeneratePreviewsForColumn:col visibleFilteredRows:[notesTableView rowsInRect:[notesTableView visibleRect]] forceUpdate:NO];
		
	 	[NSObject cancelPreviousPerformRequestsWithTarget:notesTableView selector:@selector(reloadDataIfNotEditing) object:nil];
		[notesTableView performSelector:@selector(reloadDataIfNotEditing) withObject:nil afterDelay:0.0];
	}
}

- (NSRect)splitView:(RBSplitView*)sender willDrawDividerInRect:(NSRect)dividerRect betweenView:(RBSplitSubview*)leading 
			andView:(RBSplitSubview*)trailing withProposedRect:(NSRect)imageRect {
	
	[dividerShader drawDividerInRect:dividerRect withDimpleRect:imageRect];
	
	return NSZeroRect;
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
				
				[savedSelectedNotes release];
				savedSelectedNotes = [[someNotation notesAtIndexes:indexSet] retain];
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
				[savedSelectedNotes release];
				savedSelectedNotes = nil;
				
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
    if ([prefsController quitWhenClosingWindow])
		[NSApp terminate:nil];
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
	if ([errMsg length]) NSRunAlertPanel(NSLocalizedString(@"Changes could not be uploaded.", nil), errMsg, @"Quit", nil, nil);
	
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
	return NSTerminateNow;
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
	[windowUndoManager release];
	[dividerShader release];
	
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
	
	if (![NSApp isActive]) [NSApp activateIgnoringOtherApps:YES];
	if (![window isMainWindow]) [window makeKeyAndOrderFront:sender];
	
	[self setEmptyViewState:currentNote == nil];
}

- (NSWindow*)window {
	return window;
}

@end
