//
//  SavedSearchesController.m
//  Notation
//
//  Created by Zachary Schneirov on 1/21/07.
//  Copyright 2007 __MyCompanyName__. All rights reserved.
//

#import "SavedSearchesController.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "AppController.h"
#import "NSString_NV.h"
#import "NSCollection_utils.h"

static NSString *SSSearchStringKey = @"SearchString";
static NSString *SSSelectedNoteUUIDStringKey = @"NoteUUIDString";

@implementation SavedSearch

- (id)initWithDictionary:(NSDictionary*)aDict {
	if (aDict && [self initWithSearchString:[aDict objectForKey:SSSearchStringKey]]) {

		uuidBytes = [[aDict objectForKey:SSSelectedNoteUUIDStringKey] uuidBytes];
	} else {
		NSLog(@"SavedSearch: Supplied dictionary: %@; couldn't init", aDict);
		return nil;
	}
	return self;
}
- (id)initWithSearchString:(NSString*)aString {
	if ([super init] && aString) {
		searchString = [aString copy];
		needsMenuUpdate = NO;
		
		lowercaseSearchString = [[searchString lowercaseString] retain];
		hashValue = [lowercaseSearchString hash];
	} else {
		return nil;
	}
	return self;
}

- (void)dealloc {
	[searchString release];
	[lowercaseSearchString release];
	[selectedNote release];
	
	[super dealloc];
}

- (BOOL)needsMenuUpdate {
	return needsMenuUpdate;
}
- (void)setNeedsMenuUpdate:(BOOL)value {
	needsMenuUpdate = value;
}

- (void)setSelectedNote:(NoteObject*)aNote {
	[selectedNote release];
	selectedNote = [aNote retain];
	needsMenuUpdate = YES;
	
	CFUUIDBytes zeroBytes = {0};
	CFUUIDBytes *bytes = [selectedNote uniqueNoteIDBytes];
	uuidBytes = bytes ? *bytes : zeroBytes;
}
- (NSString*)searchString {
	return searchString;
}
- (NoteObject*)selectedNote {
	if (!selectedNote) selectedNote = [[delegate noteWithUUIDBytes:uuidBytes] retain];
	return selectedNote;
}
- (NSDictionary*)dictionaryRep {
	return [NSDictionary dictionaryWithObjectsAndKeys:searchString, SSSearchStringKey, 
		[NSString uuidStringWithBytes:uuidBytes], SSSelectedNoteUUIDStringKey, nil];
}

- (NSString *)description {
	NoteObject *note = [self selectedNote];
	return note ? [NSString stringWithFormat:@"%@ [%@]", searchString, titleOfNote(note)] : searchString;
}

- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}

- (id)delegate {
	return delegate;
}

- (NSString*)lowercaseString {
	return lowercaseSearchString;
}

- (BOOL)isEqual:(id)anObject {
    return [lowercaseSearchString isEqualToString:[anObject lowercaseString]];
}
- (unsigned)hash {
    return hashValue;
}


@end


#define MovedSearchesType @"NVMovedSearchesType"

@implementation SavedSearchesController

- (id)init {
	if ([super init]) {
		searches = [[NSMutableArray alloc] init];
		searchSet = [[NSMutableSet alloc] init];
		isSelectingProgrammatically = isRestoringSearch = NO;
		
		prefsController = [GlobalPrefs defaultPrefs];
		autosaveNotesForSavedSearches = [prefsController autosaveNotesForSavedSearches];
	}
	return self;
}

- (void)awakeFromNib {
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tableViewSelectionDidChange:) 
												   name:NSTableViewSelectionDidChangeNotification object:searchesTableView];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tableViewSelectionDidChange:) 
												 name:NSTableViewSelectionIsChangingNotification object:searchesTableView];
	[window setDelegate:self];
	[rememberLastNoteButton setState:autosaveNotesForSavedSearches];
	
	[searchesTableView registerForDraggedTypes:[NSArray arrayWithObjects:MovedSearchesType, nil]];
}

- (void)dealloc {
	[searchSet release];
	[searches release];
	[super dealloc];
}

- (id)initWithSearches:(NSArray*)array {
	if ([self init]) {
		unsigned int i;
		for (i=0; i<[array count]; i++) {
			NSDictionary *dict = [array objectAtIndex:i];
			SavedSearch *search = [[SavedSearch alloc] initWithDictionary:dict];
			[search setDelegate:self];
			[searches addObject:search];
			[search release];
		}
		
		[searchSet addObjectsFromArray:searches];
	}

	return self;
}

- (NSArray*)dictionaryReps {
	
	NSMutableArray *array = [NSMutableArray arrayWithCapacity:[searches count]];
	unsigned int i;
	for (i=0; i<[searches count]; i++) {
		NSDictionary *dict = [[searches objectAtIndex:i] dictionaryRep];
		if (dict) [array addObject:dict];
	}
	
	return array;
}

- (void)setNotes:(NSArray*)someNotes {
	[notes release];
	notes = [someNotes retain];
}

- (NoteObject*)noteWithUUIDBytes:(CFUUIDBytes)bytes {
	unsigned noteIndex = [notes indexOfNoteWithUUIDBytes:&bytes];
	if (noteIndex != NSNotFound) return [notes objectAtIndex:noteIndex];
	return nil;
}


- (void)setSearchesMenu {
	
	NSMenu *menu = [NSApp mainMenu];
	NSMenu *searchesMenu = [[menu itemWithTag:103] submenu];
	while ([searchesMenu numberOfItems]) {
		[searchesMenu removeItemAtIndex:0];
	}
		
	NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:@"Show Saved Searches" action:@selector(showSearches:) keyEquivalent:@"0"] autorelease];
	[theMenuItem setTarget:self];
	[searchesMenu addItem:theMenuItem];
	
	[searchesMenu addItem:[NSMenuItem separatorItem]];
		
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:@"Add to Saved Searches" action:@selector(addSearch:) keyEquivalent:@"D"] autorelease];
	[theMenuItem setTarget:self];
	[searchesMenu addItem:theMenuItem];
	
	if ([searches count] > 0) [searchesMenu addItem:[NSMenuItem separatorItem]];
	
	unsigned int i;
	for (i=0; i<[searches count]; i++) {

		SavedSearch *search = [searches objectAtIndex:i];
		theMenuItem = [[[NSMenuItem alloc] initWithTitle:[search description] action:@selector(restoreSearch:) 
										   keyEquivalent:[NSString stringWithFormat:@"%d", (i % 9) + 1]] autorelease];
		if (i > 8) [theMenuItem setKeyEquivalentModifierMask:NSCommandKeyMask | NSShiftKeyMask];
		[theMenuItem setRepresentedObject:search];
		[theMenuItem setTarget:self];
		[searchesMenu addItem:theMenuItem];
	}
}

- (void)updateSearches {
	
	[searchSet setSet:[NSSet setWithArray:searches]];
	
	[prefsController setSavedSearchesFromSender:self];
	
	[self setSearchesMenu];
	
	[searchesTableView reloadData];
}

- (void)selectSearchInTableView:(SavedSearch*)search {
	if (searchesTableView && search) {
		//find saved search index and select
		unsigned searchIndex = [searches indexOfObjectIdenticalTo:search];
		if (searchIndex != NSNotFound) {
			isSelectingProgrammatically = YES;
			[searchesTableView selectRow:searchIndex byExtendingSelection:NO];
			isSelectingProgrammatically = NO;
		}
	}
}

- (BOOL)validateMenuItem:(id <NSMenuItem>)menuItem {
	//need to fix this for better style detection
	
	SEL action = [menuItem action];
	if (action == @selector(addSearch:)) {
		
		return ([searches count] < 17 && [[self effectiveDelegateSearchString] length]);
		
	} else if (action == @selector(restoreSearch:)) {
		//typedString equals saved search string
		SavedSearch *search = [menuItem representedObject];
		[menuItem setState:[[self effectiveDelegateSearchString] isEqualToString:[search searchString]]];
		
		if ([search needsMenuUpdate]) {
			[menuItem setTitle:[search description]];
			[search setNeedsMenuUpdate:NO];
		}
	}
	
	return YES;
}

- (BOOL)restoreLastSearch {
	return [self restoreSavedSearch:[prefsController lastSavedSearch]];
}

- (BOOL)restoreSavedSearch:(SavedSearch*)search {
	if (search) {

		//communicate with revealer here--tell it to search for this string
		if ([revealTarget respondsToSelector:revealAction]) {
			isRestoringSearch = YES;
			
			[revealTarget performSelector:revealAction withObject:search];
			[self selectSearchInTableView:search];
			
			isRestoringSearch = NO;
		} else {
			NSLog(@"reveal target %@ doesn't respond to %s!", revealTarget, revealAction);
			return NO;
		}
		return YES;
	}
	return NO;
}

- (void)restoreSearch:(id)sender {
	[self restoreSavedSearch:[sender representedObject]];
}

- (BOOL)addSearchString:(NSString*)string selectedNote:(NoteObject*)aNote {
	BOOL added = NO;
	if (string) {
		SavedSearch *search = [[SavedSearch alloc] initWithSearchString:string];
		[search setSelectedNote:aNote];
		
		if (![searchSet containsObject:search]) {
			[search setDelegate:self];
			[searches addObject:search];
			added = YES;
		} else {
			//just set selected note on existing search
			[[searchSet member:string] setSelectedNote:aNote];
		}
		[self updateSearches];
		[search release];
	}
	
	return added;
}

- (void)setLastSelectedNote:(NoteObject*)aNote forSearchString:(NSString*)aString {
	SavedSearch *search = [self setNote:aNote forSearchString:aString];
	if (!search && aString) {
		//make a new search and set it in prefs
		search = [[SavedSearch alloc] initWithSearchString:aString];
		[search setSelectedNote:aNote];
		[search autorelease];
	}
	[prefsController setLastSavedSearch:search sender:self];
}

- (void)setSelectedNoteForCurrentSearch:(NoteObject*)aNote {
	if (autosaveNotesForSavedSearches) {
		/*SavedSearch *search = */ [self setNote:aNote forSearchString:[self effectiveDelegateSearchString]];
		/*if (search && [window isVisible]) {
			[self selectSearchInTableView:search];
		}*/
	}
}

- (SavedSearch*)setNote:(NoteObject*)aNote forSearchString:(NSString*)aString {
	//NSLog(@"setNote: %@", aNote ? titleOfNote(aNote) : nil);
	if (!isRestoringSearch) {
		SavedSearch *search = [self savedSearchWithString:aString];
		if (search) {			
			[search setSelectedNote:aNote];
			
			if ([window isVisible]) {
				//show description for this saved search with the new note title
				[searchesTableView reloadData];
			}
		}
		return search;
	}
	return nil;
}

- (SavedSearch*)savedSearchWithString:(NSString*)string {
	if (![string length]) return nil;
	
	return [searchSet member:string];
}

- (SavedSearch*)savedSearchAtIndex:(int)searchIndex {
	return [searches objectAtIndex:searchIndex];
}

- (NSString*)effectiveDelegateSearchString {
	return [[delegate fieldSearchString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)setSearchString:(NSString*)aString atIndex:(unsigned int)oldIndex {
	
    if (oldIndex < [searches count]) {
		
		if ([aString length] > 0) {
			SavedSearch *search = [[SavedSearch alloc] initWithSearchString:aString];
			
			if (![search isEqual:[searches objectAtIndex:oldIndex]]) {
				[search setDelegate:self];
				[searches replaceObjectAtIndex:oldIndex withObject:search];
			}
			[search release];
			
		} else if (![[[searches objectAtIndex:oldIndex] searchString] length]) {
			return NO;
		}
    }
	
	return YES;
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex {
	if ([[aTableColumn identifier] isEqualToString:@"searchString"])
		return [[searches objectAtIndex:rowIndex] description];
	
	static NSString *shiftCharStr = nil, *cmdCharStr = nil;
	if (!cmdCharStr) {
		unichar ch = 0x2318;
		cmdCharStr = [[NSString stringWithCharacters:&ch length:1] retain];
		ch = 0x21E7;
		shiftCharStr = [[NSString stringWithCharacters:&ch length:1] retain];
	}
	
	return [NSString stringWithFormat:@"%@%@ %d", rowIndex > 8 ? shiftCharStr : @"", cmdCharStr, (rowIndex % 9) + 1];
}

- (int)numberOfRowsInTableView:(NSTableView *)aTableView {
    return [searches count];
}


- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject forTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex {
	
	if (![self setSearchString:anObject atIndex:(unsigned int)rowIndex])
		if (rowIndex > -1) [searches removeObjectAtIndex:rowIndex];
	
	[self updateSearches];
	
	//remove search and re-add with new string, at same index
	//[objects[rowIndex] performSelector:columnAttributeMutator((NoteAttributeColumn*)aTableColumn) withObject:anObject];
}


- (void)tableViewSelectionDidChange:(NSNotification *)aNotification {
	if (!isRestoringSearch && !isSelectingProgrammatically) {
		int row = [searchesTableView selectedRow];
		if (row > -1) [self restoreSavedSearch:[searches objectAtIndex:row]];
		
		[removeSearchButton setEnabled: row > -1];
	}
}

- (BOOL)tableView:(NSTableView *)tv writeRows:(NSArray*)rows toPasteboard:(NSPasteboard*)pboard {
    NSArray *typesArray = [NSArray arrayWithObject:MovedSearchesType];
	
	[pboard declareTypes:typesArray owner:self];
    [pboard setPropertyList:rows forType:MovedSearchesType];
	
    return YES;
}

- (NSDragOperation)tableView:(NSTableView*)tv validateDrop:(id <NSDraggingInfo>)info proposedRow:(int)row
	   proposedDropOperation:(NSTableViewDropOperation)op {
    
    NSDragOperation dragOp = ([info draggingSource] == searchesTableView) ? NSDragOperationMove : NSDragOperationCopy;
	
    [tv setDropRow:row dropOperation:NSTableViewDropAbove];
	
    return dragOp;
}

- (BOOL)tableView:(NSTableView*)tv acceptDrop:(id <NSDraggingInfo>)info row:(int)row dropOperation:(NSTableViewDropOperation)op {
    if (row < 0)
		row = 0;
    
    if ([info draggingSource] == searchesTableView) {
		NSArray *rows = [[info draggingPasteboard] propertyListForType:MovedSearchesType];
		int theRow = [[rows objectAtIndex:0]intValue];
		
		id object = [[searches objectAtIndex:theRow] retain];
		
		if (row != theRow + 1 && row != theRow) {
			SavedSearch* selectedSearch = nil;
			int selRow = [searchesTableView selectedRow];
			if (selRow > -1) selectedSearch = [searches objectAtIndex:selRow];
			
			if (row < theRow)
				[searches removeObjectAtIndex:theRow];
			
			if (row <= [searches count])
				[searches insertObject:object atIndex:row];
			else
				[searches addObject:object];
			
			if (row > theRow)
				[searches removeObjectAtIndex:theRow];
			
			[object release];
			
			[self updateSearches];
			[self selectSearchInTableView:selectedSearch];
			
			return YES;
		}
		return NO;
    }
	
	return NO;
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)sender defaultFrame:(NSRect)defaultFrame {
	
	float oldHeight = 0.0;
	float newHeight = 0.0;
	NSRect newFrame = [sender frame];
	NSSize intercellSpacing = [searchesTableView intercellSpacing];
	
	newHeight = [searchesTableView numberOfRows] * ([searchesTableView rowHeight] + intercellSpacing.height);	
	oldHeight = [[[searchesTableView enclosingScrollView] contentView] frame].size.height;
	newHeight = [sender frame].size.height - oldHeight + newHeight;
	
	//adjust origin so the window sticks to the upper left
	newFrame.origin.y = newFrame.origin.y + newFrame.size.height - newHeight;
	
	newFrame.size.height = newHeight;
	return newFrame;
}


- (void)changeRememberLastNote:(id)sender {
	autosaveNotesForSavedSearches = [rememberLastNoteButton state];
	[prefsController setAutosaveNotesForSavedSearches:autosaveNotesForSavedSearches sender:self];
}

- (void)showSearches:(id)sender {
	if (!window) {
		if (![NSBundle loadNibNamed:@"SavedSearches" owner:self])  {
			NSLog(@"Failed to load SavedSearches.nib");
			NSBeep();
			return;
		}
		[searchesTableView setDataSource:self];
	}
	
	[searchesTableView reloadData];
	[window makeKeyAndOrderFront:self];

	//highlight searches as appropriate while the window is open
	//selecting a search restores it
}

- (void)clearAllSearches:(id)sender {
	if (NSRunAlertPanel(@"Remove all saved searches?", @"You cannot undo this action.", 
						@"Remove All Searches", @"Cancel", NULL) == NSAlertDefaultReturn) {

		[searches removeAllObjects];
	
		[self updateSearches];
	}
}

- (void)addSearch:(id)sender {
	
	if ([searchesTableView currentEditor] && ![[[searchesTableView currentEditor] string] length])
		return;
	
	//this method is not quite consistent with what would make sense
	if ([searches count] < 17) {
		//there are only so many numbers and modifiers
		NSString *newString = [self effectiveDelegateSearchString];
		BOOL added = [self addSearchString:newString selectedNote:[delegate selectedNoteObject]];
		
		//only allow adding duplicates from the button, in which case a new blank item is created
		if (!added && sender == addSearchButton)
			added = [self addSearchString:(newString = @"") selectedNote:[delegate selectedNoteObject]];
		
		if (added && ![newString length]) {
			[searchesTableView selectRow:[searches count] - 1 byExtendingSelection:NO];
			[searchesTableView editColumn:0 row:[searches count] - 1 withEvent:nil select:YES];
		}
	}
}

- (void)removeSearch:(id)sender {
	
	SavedSearch *search = nil;
	int row = [searchesTableView selectedRow];
	if (row > -1) {
		search = [searches objectAtIndex:row];
		[searches removeObjectIdenticalTo:search];
		[self updateSearches];
	}
}

- (void)setRevealTarget:(id)target selector:(SEL)selector {
	revealTarget = target;
	revealAction = selector;
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)aDelegate {
	if ([aDelegate respondsToSelector:@selector(fieldSearchString)] && 
		[aDelegate respondsToSelector:@selector(selectedNoteObject)]) {
		delegate = aDelegate;
	} else {
		NSLog(@"Delegate %@ doesn't respond to our selectors!", aDelegate);
	}
}

@end
