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


#import "NotesTableView.h"
#import "AppController.h"
#import "FastListDataSource.h"
#import "NoteAttributeColumn.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NoteObject.h"
#import "NSCollection_utils.h"
#import "HeaderViewWithMenu.h"
#import "NSString_NV.h"

#define STATUS_STRING_FONT_SIZE 16.0f
#define SET_DUAL_HIGHLIGHTS 0

@implementation NotesTableView

//there's something wrong with this initialization under panther, I think
- (id)initWithCoder:(NSCoder *)decoder {
    if ((self = [super initWithCoder:decoder])) {
	
	globalPrefs = [GlobalPrefs defaultPrefs];
		
	loadStatusString = NSLocalizedString(@"Loading Notes...",nil);
	loadStatusAttributes = [[NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont fontWithName:@"Helvetica" size:STATUS_STRING_FONT_SIZE], NSFontAttributeName,
		[NSColor colorWithCalibratedRed:0.0f green:0.0f blue:0.0f alpha:0.5f], NSForegroundColorAttributeName, nil] retain];
	loadStatusStringWidth = [loadStatusString sizeWithAttributes:loadStatusAttributes].width;
	
	affinity = 0;
	shouldUseSecondaryHighlightColor = viewMenusValid = NO;
	firstRowIndexBeforeSplitResize = NSNotFound;
	
	headerView = [[HeaderViewWithMenu alloc] init];
	[headerView setTableView:self];
	[headerView setFrame:[[self headerView] frame]];
	cornerView = [[self cornerView] retain];
	
	NSFont *font = [NSFont systemFontOfSize:[globalPrefs tableFontSize]];
	NSArray *columnsToDisplay = [globalPrefs visibleTableColumns];
	allColumns = [[NSMutableArray alloc] init];
		
	id (*titleReferencor)(id, id) = [globalPrefs tableColumnsShowPreview] ? tableTitleOfNote : titleOfNote2;
	
	NSString *colStrings[] = { NoteTitleColumnString, NoteLabelsColumnString, NoteDateModifiedColumnString, NoteDateCreatedColumnString };
	SEL colMutators[] = { @selector(setTitleString:), @selector(setLabelString:), NULL, NULL };
	id (*colReferencors[])(id, id) = {titleReferencor, labelsOfNote2, dateModifiedStringOfNote, dateCreatedStringOfNote };
	NSInteger (*sortFunctions[])(id*, id*) = { compareTitleString, compareLabelString, compareDateModified, compareDateCreated };
	NSInteger (*reverseSortFunctions[])(id*, id*) = { compareTitleStringReverse, compareLabelStringReverse, compareDateModifiedReverse, 
	    compareDateCreatedReverse };
	
	unsigned int i;
	for (i=0; i<sizeof(colStrings)/sizeof(NSString*); i++) {
	    NoteAttributeColumn *column = [[NoteAttributeColumn alloc] initWithIdentifier:colStrings[i]];
	    [column setEditable:(colMutators[i] != NULL)];
		[column setHeaderCell:[[[NoteTableHeaderCell alloc] initTextCell:[[NSBundle mainBundle] localizedStringForKey:colStrings[i] value:@"" table:nil]] autorelease]];

	    [[column dataCell] setFont:font];
	    [column setMutatingSelector:colMutators[i]];
	    [column setDereferencingFunction:colReferencors[i]];
	    [column setSortingFunction:sortFunctions[i]];
	    [column setReverseSortingFunction:reverseSortFunctions[i]];
		[column setResizingMask:NSTableColumnUserResizingMask];
		
		[allColumns addObject:column];
	    [column release];
	}
	
	NSLayoutManager *lm = [[NSLayoutManager alloc] init];
	[self setRowHeight:[lm defaultLineHeightForFont:font] + 2.0f];
	[lm release];
	
	//[self setAutosaveName:@"notesTable"];
	//[self setAutosaveTableColumns:YES];
	[self setAllowsColumnSelection:NO];
	//[self setVerticalMotionCanBeginDrag:NO];
		
	[self setIntercellSpacing:NSMakeSize(12, 2)];
	
	BOOL hideHeader = [columnsToDisplay count] == 1 && [columnsToDisplay containsObject:NoteTitleColumnString];
	if (hideHeader) {
		[[self cornerView] setFrameOrigin:NSMakePoint(-1000,-1000)];
		[self setCornerView:nil];
	}
	[self setHeaderView:hideHeader ? nil : headerView];
		
	[[self noteAttributeColumnForIdentifier:NoteTitleColumnString] setResizingMask:NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask];
	[self setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
		
	//[self setSortDirection:[globalPrefs tableIsReverseSorted] 
	//		 inTableColumn:[self tableColumnWithIdentifier:[globalPrefs sortedTableColumnKey]]];
	
    }
    return self;
}

- (void)dealloc {
	[loadStatusAttributes release];
    [allColumns release];
	[headerView release];
    
    [super dealloc];
}

//extracted from initialization to run in a safe way
- (void)restoreColumns {
	//somehow this invokes disk access; also removed initial col from nib
	//[self removeTableColumn:[self tableColumnWithIdentifier:@"dummyColumn"]];
	
	NSArray *columnsToDisplay = [globalPrefs visibleTableColumns];
	unsigned int i;
	for (i=0; i<[allColumns count]; i++) {
		NoteAttributeColumn *column = [allColumns objectAtIndex:i];
		if ([columnsToDisplay containsObject:[column identifier]])
			[self addTableColumn:column];
		
		[column updateWidthForHighlight];
	}
		
	[self setAutosaveName:@"notesTable"];
	[self setAutosaveTableColumns:YES];
	
	[self sizeToFit];

	[self setSortDirection:[globalPrefs tableIsReverseSorted] 
			 inTableColumn:[self tableColumnWithIdentifier:[globalPrefs sortedTableColumnKey]]];
}

- (void)awakeFromNib {
	[globalPrefs registerForSettingChange:@selector(setTableFontSize:sender:) withTarget:self];
	
	[self registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType, NSRTFPboardType, NSRTFDPboardType, NSStringPboardType, nil]];
	
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	
	[center addObserver:self selector:@selector(windowDidBecomeMain:)
				   name:NSWindowDidBecomeMainNotification object:[self window]];
	
	[center addObserver:self selector:@selector(windowDidResignMain:)
				   name:NSWindowDidResignMainNotification object:[self window]];	
	
	outletObjectAwoke(self);
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender {

	if ([sender draggingSource] == self)
		return NO;

	return YES;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender {
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender {
	return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender {
	
	if ([sender draggingSource] == self)
		return NO;
		
	return [[NSApp delegate] addNotesFromPasteboard:[sender draggingPasteboard]];
}

- (void)paste:(id)sender {
	[[NSApp delegate] addNotesFromPasteboard:[NSPasteboard generalPasteboard]];
}

- (void)_setTitleDereferencorState:(BOOL)activeStyle {
	NoteAttributeColumn *col = [self noteAttributeColumnForIdentifier:NoteTitleColumnString];
#if SET_DUAL_HIGHLIGHTS
	activeStyle = YES;
#endif
	[col setDereferencingFunction: [globalPrefs tableColumnsShowPreview] ? 
	 (activeStyle ? properlyHighlightingTableTitleOfNote : tableTitleOfNote) : titleOfNote2];
}

- (void)updateTitleDereferencorState {
	NSWindow *win = [self window];
	[self _setTitleDereferencorState: [win isMainWindow] && ([win firstResponder] == self || [self currentEditor]) ];
}

- (BOOL)becomeFirstResponder {
	[self updateTitleDereferencorState];
	
	return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {	
	[self _setTitleDereferencorState:NO];
	return [super resignFirstResponder];
}

- (void)reloadDataIfNotEditing {
	if (![self currentEditor]) {
		[self reloadData];
	}
}

- (void)reloadData {
	[headerView setIsReloading:YES];
	[super reloadData];
	[headerView setIsReloading:NO];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {

	if (!viewMenusValid && [menu delegate] == self) {
		[menu setSubmenu:[self menuForColumnConfiguration:nil] forItem:[menu itemWithTag:97]];
		[menu setSubmenu:[self menuForColumnSorting] forItem:[menu itemWithTag:98]];
		viewMenusValid = YES;
	}
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {

	if ([selectorString isEqualToString:SEL_STR(setTableFontSize:sender:)]) {
		
		NSFont *font = [NSFont systemFontOfSize:[globalPrefs tableFontSize]];
		
		NSUInteger i;
		for (i=0; i<[allColumns count]; i++)
			[[[allColumns objectAtIndex:i] dataCell] setFont:font];
		
		NSLayoutManager *lm = [[NSLayoutManager alloc] init];
		[self setRowHeight:[lm defaultLineHeightForFont:font] + 2.0f];
		[lm release];
	}
}

- (double)distanceFromRow:(int)aRow forVisibleArea:(NSRect)visibleRect {
	return [self rectOfRow:aRow].origin.y - visibleRect.origin.y;
}

- (ViewLocationContext)viewingLocation {
	ViewLocationContext ctx;
	
	int pivotRow = [[self selectedRowIndexes] firstIndex];
	
	int nRows = [self numberOfRows];
	
	NSRect visibleRect = [self visibleRect];
	NSRange range = [self rowsInRect:visibleRect];
	
	if (!NSLocationInRange(pivotRow, range)) {
		if (NSLocationInRange(nRows - 1, range)) {
			pivotRow = nRows - 1;
		} else {
			pivotRow = [self rowAtPoint:NSMakePoint(1, visibleRect.origin.y + [self rowHeight])];
		}
	}
	
	ctx.pivotRowWasEdge = (pivotRow == 0 || pivotRow == nRows - 1);
	
	ctx.nonRetainedPivotObject = nil;
	ctx.verticalDistanceToPivotRow = 0;
	
	if ((unsigned int)pivotRow < (unsigned int)nRows) {
		if ((ctx.nonRetainedPivotObject = [(FastListDataSource*)[self dataSource] immutableObjects][pivotRow])) {
			ctx.verticalDistanceToPivotRow = [self distanceFromRow:pivotRow forVisibleArea:visibleRect];
		}
	}
	return ctx;
}

- (void)setViewingLocation:(ViewLocationContext)ctx {
	if (ctx.nonRetainedPivotObject) {
		
		NSInteger pivotIndex = [(FastListDataSource*)[self dataSource] indexOfObjectIdenticalTo:ctx.nonRetainedPivotObject];
		if (pivotIndex != NSNotFound) {
			//figure out how to determine top/bottom condition:
			//if pivotRow was 0 or nRows-1, and pivotIndex is not either, then scroll maximally in the nearest direction?
			NSInteger lastRow = [self numberOfRows] - 1;
			
			if (ctx.pivotRowWasEdge && (pivotIndex != 0 && pivotIndex != lastRow)) {
				pivotIndex = abs(pivotIndex - 0) < abs(pivotIndex - lastRow) ? 0 : lastRow;
				ctx.verticalDistanceToPivotRow = 0;
				//NSLog(@"edge pivot dislodged!");
			}
			//(scroll pivotNote by verticalDistanceToPivotRow from the top)
			[self scrollRowToVisible:pivotIndex withVerticalOffset:ctx.verticalDistanceToPivotRow];	
		}
	}	
}

- (void)scrollRowToVisible:(NSInteger)rowIndex withVerticalOffset:(float)offset {
	NSRect rowRect = [self rectOfRow:rowIndex];
	
	rowRect.origin.y -= offset;
	
	NSClipView *clipView = [[self enclosingScrollView] contentView];

	[clipView scrollToPoint:[clipView constrainScrollPoint:rowRect.origin]];
	[[self enclosingScrollView] reflectScrolledClipView:clipView];
}

- (void)editRowAtColumnWithIdentifier:(id)identifier {
	
	int colIndex = [self columnWithIdentifier:identifier];
    if (colIndex < 0) {
		
		BOOL isTitleCol = [identifier isEqualToString:NoteTitleColumnString];
		int newColIndex = (int)(!isTitleCol);
		
		NSEnumerator *theEnumerator = [allColumns objectEnumerator];
		NSTableColumn *column = nil;
		while ((column = [theEnumerator nextObject]) != nil) {
			
			if ([[column identifier] isEqualToString:identifier]) {
				[self addPermanentTableColumn:column];
				[self moveColumn:[[self tableColumns] indexOfObjectIdenticalTo:column] toColumn:newColIndex];
				colIndex = newColIndex;
				[self sizeToFit];
				break;
			}
		}
	}
	
	int selected = [self selectedRow];
	if (selected > -1 && colIndex > -1) {
		[self editColumn:colIndex row:selected withEvent:[[self window] currentEvent] select:YES];
	} else NSBeep();
}

- (NoteAttributeColumn*)noteAttributeColumnForIdentifier:(NSString*)identifier {
	NSEnumerator *theEnumerator = [allColumns objectEnumerator];
    NoteAttributeColumn *theColumn = nil;
    while ((theColumn = [theEnumerator nextObject]) != nil) {
		if ([[theColumn identifier] isEqualToString:identifier])
			return theColumn;
	}

	return nil;
}

- (void)addPermanentTableColumn:(NSTableColumn*)column {
	[self addTableColumn:column];
	[globalPrefs addTableColumn:[column identifier] sender:self];
	
	if ([[column identifier] isEqualToString:[globalPrefs sortedTableColumnKey]]) {
		[(NoteAttributeColumn*)[self highlightedTableColumn] updateWidthForHighlight];
		[self setHighlightedTableColumn:column];
		[(NoteAttributeColumn*)column updateWidthForHighlight];
	}
	
	[self updateHeaderViewForColumns];
	
	viewMenusValid = NO;
}

- (void)updateHeaderViewForColumns {
	id oldHeader = [self headerView];
	id newHeader = headerView;
	
	if ([[self tableColumns] count] == 1 && [self tableColumnWithIdentifier:NoteTitleColumnString]) {
	    
	    //if only displaying title, remove the column header; it is redundant
		newHeader = nil;
	}
	
	if (oldHeader != newHeader) {
		//[headerView setTableView:newHeader ? self : nil];
		[self setHeaderView:newHeader];
		[self setCornerView:newHeader ? cornerView : nil];
	
		if ([self respondsToSelector:@selector(_sizeRowHeaderToFitIfNecessary)]) {
			//hopefully 10.5 has this
			[self _sizeRowHeaderToFitIfNecessary];
		} else if ([self respondsToSelector:@selector(_sizeToFitIfNecessary)]) {
			//probably only on 10.3.x
			[self _sizeToFitIfNecessary];
			[[self enclosingScrollView] setNeedsDisplay:YES];
		} else {
			//anything else
			NSWindow *win = [self window];
			NSRect frame = [win frame];
			
			//this is a nasty little hack
			frame.size.height -= 2.6;
			frame.size.width -= 2.6;
			[win setFrame:frame display:NO];
			frame.size.height += 2.6;
			frame.size.width += 2.6;
			[win setFrame:frame display:YES];
		}
		//[self tile];
	}
}

- (IBAction)actionHideShowColumn:(id)sender {
    NSTableColumn *column = [sender representedObject]; 
    if ([[self tableColumns] containsObject:column]) {
		
		if ([self numberOfColumns] > 1) {
			[self abortEditing];
			[self removeTableColumn:column];
			[globalPrefs removeTableColumn:[column identifier] sender:self];
			viewMenusValid = NO;
		} else {
			NSBeep();
		}
		
		[self updateHeaderViewForColumns];
		
    } else {
		[self addPermanentTableColumn:column];
		
		NSArray *cols = [self tableColumns];
		
		unsigned addedColIndex = [cols indexOfObjectIdenticalTo:column];
		unsigned clickedColIndex = [sender tag];
		
		if (clickedColIndex < [cols count] && addedColIndex < [cols count])
			[self moveColumn:addedColIndex toColumn:clickedColIndex+1];
    }
    
    [self sizeToFit];
}

- (IBAction)toggleNoteBodyPreviews:(id)sender {
	[globalPrefs setTableColumnsShowPreview: ![globalPrefs tableColumnsShowPreview] sender:self];
}

- (NSMenu *)menuForColumnSorting {
	NSMenu *theMenu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    
    NSEnumerator *theEnumerator = [allColumns objectEnumerator];
    NSTableColumn *theColumn = nil;
	NSString *sortKey = [globalPrefs sortedTableColumnKey];
	
    while ((theColumn = [theEnumerator nextObject]) != nil) {
		NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:[[theColumn headerCell] stringValue] 
															  action:@selector(setStatusForSortedColumn:) 
													   keyEquivalent:@""] autorelease];
		[theMenuItem setTarget:self];
		[theMenuItem setRepresentedObject:theColumn];
		[theMenuItem setState:[[theColumn identifier] isEqualToString:sortKey]];
		
		[theMenu addItem:theMenuItem];
    }
    return theMenu;
}

- (NSMenu *)menuForColumnConfiguration:(NSTableColumn *)inSelectedColumn {
    NSMenu *theMenu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    
    NSArray *cols = [self tableColumns];
    NSEnumerator *theEnumerator = [allColumns objectEnumerator];
    NSTableColumn *theColumn = nil;
    while ((theColumn = [theEnumerator nextObject]) != nil) {
		NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:[[theColumn headerCell] stringValue] 
															  action:@selector(actionHideShowColumn:) 
													   keyEquivalent:@""] autorelease];
		[theMenuItem setTarget:self];
		[theMenuItem setRepresentedObject:theColumn];
		[theMenuItem setState:[cols containsObject:theColumn]];
		[theMenuItem setTag:(inSelectedColumn ? [cols indexOfObjectIdenticalTo:inSelectedColumn] : 0)];
		
		[theMenu addItem:theMenuItem];
    }
    return theMenu;
}

- (void)setStatusForSortedColumn:(id)sender {
	NSTableColumn* tableColumn = (NSTableColumn*)sender;
	NSString *lastColumnName = [globalPrefs sortedTableColumnKey];
	BOOL sortDescending = [globalPrefs tableIsReverseSorted];
	
	if ([sender isKindOfClass:[NSMenuItem class]])
		tableColumn = [sender representedObject];
	
    if ([lastColumnName isEqualToString:[tableColumn identifier]]) {
		//User clicked same column, change sort order
		sortDescending = !sortDescending;
    } else {
		//user clicked new column
		//sortDescending = NO;
		viewMenusValid = NO;
	}
	
    // save new sorting selector, and re-sort the array.
	NoteAttributeColumn *lastCol = nil;
    if (lastColumnName) {
		lastCol = [self noteAttributeColumnForIdentifier:lastColumnName];
		[self setIndicatorImage:nil inTableColumn:lastCol];
    }
    
	[self setSortDirection:sortDescending inTableColumn:tableColumn];
	[globalPrefs setSortedTableColumnKey:[tableColumn identifier] reversed:sortDescending sender:self];
	[lastCol updateWidthForHighlight];
}

- (void)setSortDirection:(BOOL)direction inTableColumn:(NSTableColumn*)tableColumn {
    [self setHighlightedTableColumn:tableColumn];
    
    // Set the graphic for the new column header
    [self setIndicatorImage: (direction ? [NSImage imageNamed:@"NSDescendingSortIndicator"] : 
							  [NSImage imageNamed:@"NSAscendingSortIndicator"]) inTableColumn:tableColumn];	
	
	[(NoteAttributeColumn*)tableColumn updateWidthForHighlight];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e {
    return YES;
}

- (NSMenu *)menuForEvent:(NSEvent *)theEvent {
    NSPoint mousePoint = [self convertPoint:[theEvent locationInWindow] fromView:nil];
    int row = [self rowAtPoint:mousePoint];
	
    if (row >= 0) {
		[self selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
		  byExtendingSelection:[[self selectedRowIndexes] containsIndex:row] && [[self selectedRowIndexes] count] > 1];
	}
	
	if (![self numberOfSelectedRows])
		return nil;
	
	return [self defaultNoteCommandsMenuWithTarget:[NSApp delegate]];
}

- (NSMenu *)defaultNoteCommandsMenuWithTarget:(id)target {
	NSMenu *theMenu = [[[NSMenu alloc] initWithTitle:@"Contextual Note Commands Menu"] autorelease];
    
	NSMenu *notesMenu = [[[NSApp mainMenu] itemWithTag:NOTES_MENU_ID] submenu];
	
	int menuIndex = [notesMenu indexOfItemWithTarget:target andAction:@selector(renameNote:)];
	if (menuIndex > -1)	[theMenu addItem:[[(NSMenuItem*)[notesMenu itemAtIndex:menuIndex] copy] autorelease]];
	
	menuIndex = [notesMenu indexOfItemWithTarget:target andAction:@selector(tagNote:)];
	if (menuIndex > -1)	[theMenu addItem:[[(NSMenuItem*)[notesMenu itemAtIndex:menuIndex] copy] autorelease]];
	
	menuIndex = [notesMenu indexOfItemWithTarget:target andAction:@selector(deleteNote:)];
	if (menuIndex > -1)	[theMenu addItem:[[(NSMenuItem*)[notesMenu itemAtIndex:menuIndex] copy] autorelease]];
	
	[theMenu addItem:[NSMenuItem separatorItem]];
	
	menuIndex = [notesMenu indexOfItemWithTarget:target andAction:@selector(exportNote:)];
	if (menuIndex > -1)	[theMenu addItem:[[(NSMenuItem*)[notesMenu itemAtIndex:menuIndex] copy] autorelease]];
	
	[theMenu addItem:[NSMenuItem separatorItem]];
	
	menuIndex = [notesMenu indexOfItemWithTarget:target andAction:@selector(printNote:)];
	if (menuIndex > -1)	[theMenu addItem:[[(NSMenuItem*)[notesMenu itemAtIndex:menuIndex] copy] autorelease]];
	
	NSArray *notes = [(FastListDataSource*)[self dataSource] objectsAtFilteredIndexes:[self selectedRowIndexes]];
	//NSMenuItem *copyURLsItem = [theMenu addItemWithTitle:@"Copy Link to Clipboard" action:NULL keyEquivalent:@""];
	[notes addMenuItemsForURLsInNotes:theMenu];
	
	return theMenu;
}


- (BOOL)objectIsSelected:(id)obj {
	NSIndexSet *indexSet = nil;
	
	const id *objects = [(FastListDataSource*)[self dataSource] immutableObjects];
	if (!objects) return NO;
		
	//check for single-selections first to avoid selectedRowIndexes, which will always create a new object
	if ([self numberOfSelectedRows] == 1) {
		NSInteger selRowIndex = [self selectedRow];
		if (selRowIndex >= 0) {
			return obj == objects[selRowIndex];
		}
	}
	
	indexSet = [self selectedRowIndexes];
	NSUInteger count = (NSUInteger)[self numberOfRows];
	NSUInteger indexBuffer[20];
	NSUInteger bufferIndex, firstIndex = [indexSet firstIndex];
	NSUInteger indexCount = 1;
	NSRange range = NSMakeRange(firstIndex, [indexSet lastIndex]-firstIndex+1);
	
	while ((indexCount = [indexSet getIndexes:indexBuffer maxCount:20 inIndexRange:&range])) {
		
		for (bufferIndex=0; bufferIndex < indexCount; bufferIndex++) {
			NSUInteger objIndex = indexBuffer[bufferIndex];
			if (objIndex < count && obj == objects[objIndex]) return YES;
		}
	}
	
    return NO;
}


- (void)windowDidBecomeMain:(NSNotification *)aNotification  {
	[self setShouldUseSecondaryHighlightColor:hadHighlightInForeground];
	[self updateTitleDereferencorState];
}

- (void)windowDidResignMain:(NSNotification *)aNotification {
	BOOL highlightBefore = shouldUseSecondaryHighlightColor;
	[self setShouldUseSecondaryHighlightColor:YES];
	hadHighlightInForeground = highlightBefore;
	[self updateTitleDereferencorState];
}

- (void)setShouldUseSecondaryHighlightColor:(BOOL)value {
#if SET_DUAL_HIGHLIGHTS
	if (![[self window] isKeyWindow]) {
		hadHighlightInForeground = value;
		value = YES;
	}		
	shouldUseSecondaryHighlightColor = value;
	
	[self setNeedsDisplay:YES];
#endif
}

#if SET_DUAL_HIGHLIGHTS
- (BOOL)_shouldUseSecondaryHighlightColor {

	return shouldUseSecondaryHighlightColor;
}
#endif


- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal {
	return isLocal ? NSDragOperationNone : NSDragOperationCopy;
}

- (void)mouseDown:(NSEvent*)event {
	
	//this seems like it should happen automatically, but it does not.
	if (![NSApp isActive]) {
		[NSApp activateIgnoringOtherApps:YES];
	}
	if (![[self window] isKeyWindow]) {
		[[self window] makeKeyAndOrderFront:self];
	}
	
	unsigned int flags = [event modifierFlags]; 
    if (flags & NSAlternateKeyMask) { // option click starts a drag 
		
		NSPoint mousePoint = [self convertPoint:[event locationInWindow] fromView:nil];
        NSPoint dragPoint = NSMakePoint(mousePoint.x - 16, mousePoint.y + 16); 
		NSIndexSet *selectedRows = [self selectedRowIndexes];
		
		int row = [self rowAtPoint:mousePoint];
		if (row >= 0) {
			[self selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
			  byExtendingSelection:[selectedRows containsIndex:row] && [selectedRows count] > 1];
			//changed selected rows:
			selectedRows = [self selectedRowIndexes];
		}
		
        NSArray *notes = [(FastListDataSource*)[self dataSource] objectsAtFilteredIndexes:selectedRows];
		NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[notes count]];
		unsigned int i;
		for (i=0;i<[notes count]; i++) {
			NoteObject *note = [notes objectAtIndex:i];
			//for now, allow option-dragging-out only for notes with separate file-backing stores
			if (storageFormatOfNote(note) != SingleDatabaseFormat) {
				NSString *aPath = [note noteFilePath];
				if (aPath) [paths addObject:aPath];
			}
		}
		if ([paths count] > 0) {
			NSImage *image = [[NSWorkspace sharedWorkspace] iconForFile:[paths lastObject]];
			
			NSPasteboard *pboard = [NSPasteboard pasteboardWithName:NSDragPboard]; 
			[pboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
			[pboard setPropertyList:paths forType:NSFilenamesPboardType];			
			
			[NSApp preventWindowOrdering]; 
			[self dragImage:image at:dragPoint offset:NSZeroSize event:event pasteboard:pboard source:self slideBack:YES]; 
			return;
		} else {
			NSBeep();
		}
    }
	
	[super mouseDown:event];
}

#define DOWNCHAR(x) ((x) == NSDownArrowFunctionKey || (x) == NSDownTextMovement)
#define UPCHAR(x) ((x) == NSUpArrowFunctionKey || (x) == NSUpTextMovement)

- (void)keyDown:(NSEvent*)theEvent {

	unichar keyChar = [theEvent firstCharacter];

    if (keyChar == NSNewlineCharacter || keyChar == NSCarriageReturnCharacter || keyChar == NSEnterCharacter) {
		unsigned int sel = [self selectedRow];
		if (sel < (unsigned)[self numberOfRows] && [self numberOfSelectedRows] == 1) {
			int colIndex = [self columnWithIdentifier:NoteTitleColumnString];
			if (colIndex > -1) {
				[self editColumn:colIndex row:sel withEvent:theEvent select:YES];
			} else {
				[[self window] selectNextKeyView:self];
			}
			return;
		}
    } else if (keyChar == NSDeleteCharacter || keyChar == NSDeleteFunctionKey || keyChar == NSDeleteCharFunctionKey) {
		[[NSApp delegate] deleteNote:self];
		return;
	} else if (keyChar == NSTabCharacter) {
		[[self window] selectNextKeyView:self];
		return;
	} else if (keyChar == 0x1B) {
		//should be escape--just handle it normally to avoid re-forwarding flicker
		[super keyDown:theEvent];
		return;
	}
	
	NSUInteger modifiers = [theEvent modifierFlags];
	
	if (modifiers & NSCommandKeyMask) {
		//replicating up/down with option key
		if (UPCHAR(keyChar)) {
			[self selectRowAndScroll:0];
			return;
		} else if (DOWNCHAR(keyChar)) {
			[self selectRowAndScroll:[self numberOfRows]-1];
			return;
		}
	}
	
	if (modifiers & NSShiftKeyMask) {
		if (DOWNCHAR(keyChar) || UPCHAR(keyChar)) {
			
			NSIndexSet *indexes = [self selectedRowIndexes];
			int count = [indexes count];
			if (count <= 1) {                 // reset affinity, since there's at most one item selected
				affinity = 0;
			} else if (affinity == 0) {                     // affinity not set, so take current direction
				affinity = DOWNCHAR(keyChar) ? 1 : -1;      // down == down-document == means positive affinity
			} else {
				int row = -1;                           // affinity had been set, so enforce it
				if (DOWNCHAR(keyChar) && (affinity != 1)) {           // down not allowed here
					row = [indexes firstIndex];
				} else if (UPCHAR(keyChar) && (affinity != -1)) {    // up not allowed here
					row = [indexes lastIndex];
				}
				if (row >= 0) {
					int scrollTo = row - affinity;
					[self scrollRowToVisible:scrollTo];  // make sure we can see things
					[self deselectRow:row];         // deselect the last row
					return;     // skip further processing of the key event
				}
			}
		}
	}
	
	if (DOWNCHAR(keyChar) || UPCHAR(keyChar)) {
		[super keyDown:theEvent];
		return;
	}
	

	NSWindow *win = [self window];
	if ([win firstResponder] == self) {
		//forward keystroke to first responder, which should be controlField's field editor
		[win makeFirstResponder:controlField];
		NSTextView *fieldEditor = (NSTextView*)[controlField currentEditor];		
		[fieldEditor keyDown:theEvent];
	} else
		[super keyDown:theEvent];
}


enum { kNext_Tag = 'j', kPrev_Tag = 'k' };

//use this method to catch next note/prev note before View menu does
//thus avoiding annoying flicker and slow-down
- (BOOL)performKeyEquivalent:(NSEvent *)theEvent {
	
	unsigned mods = [theEvent modifierFlags];
	if (mods & NSCommandKeyMask) {
		
		unichar keyChar = [theEvent firstCharacter]; /*cannot use ignoringModifiers here as it subverts the Dvorak-Qwerty-CMD keyboard layout */
		
		if (keyChar == kNext_Tag || keyChar == kPrev_Tag) {
			
			if (mods & NSAlternateKeyMask) {
				[self selectRowAndScroll:(keyChar == kNext_Tag ? [self numberOfRows] - 1 :  0)];
			} else {
				if (!dummyItem) dummyItem = [[NSMenuItem alloc] init];
				[dummyItem setTag:keyChar];
				
				[self incrementNoteSelection:dummyItem];
			}
			return YES;
		}
	}

	return [super performKeyEquivalent:theEvent];
}

- (void)incrementNoteSelection:(id)sender {
	
	int tag = [sender tag];
	int rowNumber = [self selectedRow];
	int totalNotes = [self numberOfRows];
	
	if (rowNumber == -1) {
		rowNumber = (tag == kPrev_Tag ? totalNotes - 1 : 0);
	} else {
		rowNumber = (tag == kPrev_Tag ? 
					 (rowNumber < 1 ? rowNumber : rowNumber - 1) : 
					 (rowNumber >= totalNotes - 1 ? rowNumber : rowNumber + 1));
	}
	
	[self selectRowAndScroll:rowNumber];
}

- (void)deselectAll:(id)sender {
	
	[super deselectAll:sender];
	
	[self scrollRowToVisible:0];
}

- (void)selectRowAndScroll:(NSInteger)row {

	if (row > -1 && row < [self numberOfRows]) {
		[self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		[self scrollRowToVisible:row];
	}
}

- (BOOL)textView:(NSTextView *)aTextView doCommandBySelector:(SEL)command {
	
	if (command == @selector(moveToEndOfLine:) || command == @selector(moveToRightEndOfLine:)) {
	
		NSEvent *event = [[self window] currentEvent];
		if ([event type] == NSKeyDown && ![event isARepeat] && 
			NSEqualRanges([aTextView selectedRange], NSMakeRange([[aTextView string] length], 0))) {
			//command-right at the end of the title--jump to editing the note!
			[[self window] makeFirstResponder:[self nextValidKeyView]];
			NSText *editor = (NSText*)[self nextValidKeyView];
			if ([editor isKindOfClass:[NSText class]]) {
				[editor setSelectedRange:NSMakeRange(0, 0)];
				[editor scrollRangeToVisible:NSMakeRange(0, 0)];
			}
			return YES;
		}
	}
	return NO;
}

- (void)editColumn:(NSInteger)columnIndex row:(NSInteger)rowIndex withEvent:(NSEvent *)theEvent select:(BOOL)flag {

	[super editColumn:columnIndex row:rowIndex withEvent:theEvent select:flag];
	
	//become/resignFirstResponder can't handle the field-editor case for row-highlighting style, so do it here:
	[self updateTitleDereferencorState];
	
	//this is way easier and faster than a custom formatter! just change the title while we're editing!
	if ([self columnWithIdentifier:NoteTitleColumnString] == columnIndex) {
		//we're editing a title
		NoteObject *note = [(FastListDataSource*)[self dataSource] immutableObjects][rowIndex];
		
		NSTextView *editor = (NSTextView*)[self currentEditor];
		[editor setString:titleOfNote(note)];
		if (flag) [editor setSelectedRange:NSMakeRange(0, [titleOfNote(note) length])];
	}
}

- (void)textDidEndEditing:(NSNotification *)aNotification {
	[super textDidEndEditing:aNotification];
	[self updateTitleDereferencorState];
}

- (BOOL)abortEditing {
	BOOL result = [super abortEditing];
	[self updateTitleDereferencorState];
	return result;
}

- (void)cancelOperation:(id)sender {
	[self abortEditing];
	[[NSApp delegate] cancelOperation:sender];
}

- (void)viewWillStartLiveResize {
	[self noteFirstVisibleRow];
}

- (void)makeFirstPreviouslyVisibleRowVisibleIfNecessary {
	if (firstRowIndexBeforeSplitResize != NSNotFound) {
		
		NSRect visibleRect = [self visibleRect];
		NSRect rowRect = [self rectOfRow:firstRowIndexBeforeSplitResize];
		NSPoint rowOrigin = rowRect.origin;
		rowOrigin.y += rowRect.size.height;
		
		if (!NSPointInRect(rowOrigin, visibleRect)) {
			//NSLog(@"scrolling scrollin scrollin, get them doggies scrollin: %g", rowOrigin.y);
			[self scrollRowToVisible:firstRowIndexBeforeSplitResize];
		}
	} else {
		//aquire not-seen-on-mousedown-selected rows as they become visible due to scrolling?
	}	
}

- (void)noteFirstVisibleRow {
	firstRowIndexBeforeSplitResize = NSNotFound;
	NSUInteger newFirstRow = [[self selectedRowIndexes] firstIndex];
	NSRange range = [self rowsInRect:[self visibleRect]];
	
	if (NSLocationInRange(newFirstRow, range)) {
		firstRowIndexBeforeSplitResize = newFirstRow;
	}	
}

- (void)drawRect:(NSRect)rect {
    //force fully live resizing of columns while resizing window
    [super drawRect:rect];
	
	if (![self dataSource]) {
		NSSize size = [self bounds].size;
		NSPoint center = NSMakePoint(size.width / 2.0, size.height / 2.0);
		
		[loadStatusString drawAtPoint:NSMakePoint(center.x - loadStatusStringWidth/2.0, 
												  center.y - STATUS_STRING_FONT_SIZE/2.0) 
					   withAttributes:loadStatusAttributes];
	}
}

@end
