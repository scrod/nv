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


#import "NotesTableView.h"
#import "AppController_Importing.h"
#import "FastListDataSource.h"
#import "NoteAttributeColumn.h"
#import "ExternalEditorListController.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NoteObject.h"
#import "NSCollection_utils.h"
#import "LabelColumnCell.h"
#import "UnifiedCell.h"
#import "HeaderViewWithMenu.h"
#import "NSString_NV.h"
#import "NotesTableHeaderCell.h"
#import "LinkingEditor.h"
//#import "NotesTableCornerView.h"

#define STATUS_STRING_FONT_SIZE 16.0f
#define SET_DUAL_HIGHLIGHTS 0

#define SYNTHETIC_TAGS_COLUMN_INDEX 200

static void _CopyItemWithSelectorFromMenu(NSMenu *destMenu, NSMenu *sourceMenu, SEL aSel, id target, NSInteger tag);

@implementation NotesTableView

//there's something wrong with this initialization under panther, I think
- (id)initWithCoder:(NSCoder *)decoder {
    if ((self = [super initWithCoder:decoder])) {
		
		globalPrefs = [GlobalPrefs defaultPrefs];
      
    userDefaults = [NSUserDefaults standardUserDefaults];
    [userDefaults registerDefaults: [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithBool: NO], @"UseCtrlForSwitchingNotes", nil]];
      
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
		//	cornerView = [[self cornerView] retain];	
		[self setCornerView:nil];	
		//cornerView =[[[NotesTableCornerView alloc] initWithFrame:[[self cornerView] bounds]] retain];
		NSArray *columnsToDisplay = [globalPrefs visibleTableColumns];
		allColumns = [[NSMutableArray alloc] initWithCapacity:4];
		allColsDict = [[NSMutableDictionary alloc] initWithCapacity:4];
		
		id (*titleReferencor)(id, id, NSInteger) = [globalPrefs horizontalLayout] ? 
		([globalPrefs tableColumnsShowPreview] ? unifiedCellForNote : unifiedCellSingleLineForNote) :
		([globalPrefs tableColumnsShowPreview] ? tableTitleOfNote : titleOfNote2);
		
		NSString *colStrings[] = { NoteTitleColumnString, NoteLabelsColumnString, NoteDateModifiedColumnString, NoteDateCreatedColumnString };
		SEL colMutators[] = { @selector(setTitleString:), @selector(setLabelString:), NULL, NULL };
		id (*colReferencors[])(id, id, NSInteger) = {titleReferencor, labelColumnCellForNote, dateModifiedStringOfNote, dateCreatedStringOfNote };
		NSInteger (*sortFunctions[])(id*, id*) = { compareTitleString, compareLabelString, compareDateModified, compareDateCreated };
		NSInteger (*reverseSortFunctions[])(id*, id*) = { compareTitleStringReverse, compareLabelStringReverse, compareDateModifiedReverse, 
			compareDateCreatedReverse };
		
		unsigned int i;
		for (i=0; i<sizeof(colStrings)/sizeof(NSString*); i++) {
			NoteAttributeColumn *column = [[NoteAttributeColumn alloc] initWithIdentifier:colStrings[i]];
			[column setEditable:(colMutators[i] != NULL)];
			[column setHeaderCell:[[[NotesTableHeaderCell alloc] initTextCell:[[NSBundle mainBundle] localizedStringForKey:colStrings[i] value:@"" table:nil]] autorelease]];
			
			[column setMutatingSelector:colMutators[i]];
			[column setDereferencingFunction:colReferencors[i]];
			[column setSortingFunction:sortFunctions[i]];
			[column setReverseSortingFunction:reverseSortFunctions[i]];
			[column setResizingMask:NSTableColumnUserResizingMask];
			
			[allColsDict setObject:column forKey:colStrings[i]];
			[allColumns addObject:column];
			[column release];
		}
		
		[[self noteAttributeColumnForIdentifier:NoteLabelsColumnString] setDataCell: [[[LabelColumnCell alloc] init] autorelease]];
		[self _configureAttributesForCurrentLayout];
		[self setAllowsColumnSelection:NO];
		//[self setVerticalMotionCanBeginDrag:NO];
		
		BOOL hideHeader = (([columnsToDisplay count] == 1 && [columnsToDisplay containsObject:NoteTitleColumnString]) || [globalPrefs horizontalLayout]);
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
	[allColsDict release];
	[headerView release];
    
    [super dealloc];
}

//extracted from initialization to run in a safe way
- (void)restoreColumns {
	unsigned int i;
	
	//if columns currently exist, then remove them first, so that nstableview's autosave/restore works properly
	if ([[self tableColumns] count]) {
		for (i=0; i<[allColumns count]; i++) {
			[self removeTableColumn:[allColumns objectAtIndex:i]];
		}
	}
	
	//horizontal view has only a single column; store column widths separately for it
	NSArray *columnsToDisplay = [globalPrefs horizontalLayout] ? [NSArray arrayWithObject:NoteTitleColumnString] : [globalPrefs visibleTableColumns];
	
	for (i=0; i<[allColumns count]; i++) {
		NoteAttributeColumn *column = [allColumns objectAtIndex:i];
		if ([columnsToDisplay containsObject:[column identifier]])
			[self addTableColumn:column];
		
		[column updateWidthForHighlight];
	}	
	
	[self setAutosaveName:[globalPrefs horizontalLayout] ? @"unifiedNotesTable" : @"notesTable"];
	[self setAutosaveTableColumns:YES];
	
	[self sizeToFit];
	
	[self setSortDirection:[globalPrefs tableIsReverseSorted] 
			 inTableColumn:[self tableColumnWithIdentifier:[globalPrefs sortedTableColumnKey]]];
}

- (void)awakeFromNib {
	[globalPrefs registerWithTarget:self forChangesInSettings:
	 @selector(setTableFontSize:sender:),
	 @selector(setHorizontalLayout:sender:), nil];
	
	[self registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType, NSRTFPboardType, NSRTFDPboardType, NSStringPboardType, nil]];
	
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	
	[center addObserver:self selector:@selector(windowDidBecomeMain:)
				   name:NSWindowDidBecomeMainNotification object:[self window]];
	
	[center addObserver:self selector:@selector(windowDidResignMain:)
				   name:NSWindowDidResignMainNotification object:[self window]];	
	//[self setb]
    [[self enclosingScrollView] setDrawsBackground:NO];
    
   // [self setBackgroundColor:[NSColor clearColor]];
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

- (float)tableFontHeight {
	return tableFontHeight;
}

- (BOOL)isActiveStyle {
	return isActiveStyle;
}

- (void)_setActiveStyleState:(BOOL)activeStyle {
	NoteAttributeColumn *col = [self noteAttributeColumnForIdentifier:NoteTitleColumnString];
#if SET_DUAL_HIGHLIGHTS
	activeStyle = YES;
#endif
	isActiveStyle = activeStyle;
	[col setDereferencingFunction: [globalPrefs horizontalLayout] ? ([globalPrefs tableColumnsShowPreview] ? unifiedCellForNote : unifiedCellSingleLineForNote) : 
	 ([globalPrefs tableColumnsShowPreview] ? (activeStyle ? properlyHighlightingTableTitleOfNote : tableTitleOfNote) : titleOfNote2)];
}

- (void)updateTitleDereferencorState {
	NSWindow *win = [self window];
	[self _setActiveStyleState: [win isMainWindow] && ([win firstResponder] == self || [self currentEditor]) ];
   
}

- (BOOL)becomeFirstResponder {
	[self updateTitleDereferencorState];
	
	return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {	
	[self _setActiveStyleState:NO];
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
	
	if (!viewMenusValid && [menu delegate] == (id)self) {
		[menu setSubmenu:[self menuForColumnConfiguration:nil] forItem:[menu itemWithTag:97]];
		[menu setSubmenu:[self menuForColumnSorting] forItem:[menu itemWithTag:98]];
		
		viewMenusValid = YES;		
	}
}

- (void)drawGridInClipRect:(NSRect)clipRect {
    
	//draw lines manually to avoid interfering with title-focusrings and selection highlighting on leopard+
	if (![self dataSource]) {
		return;
	}
	[NSGraphicsContext saveGraphicsState];
    [[NSGraphicsContext currentContext] setShouldAntialias:NO];
	
	NSBezierPath *line = [NSBezierPath bezierPath];
    NSUInteger i;
	
    [[self gridColor] setStroke];
	
	NSIndexSet *set = [self selectedRowIndexes];
	NSInteger editedRow = [self editedRow];
	
	NSRange rangeOfRows = [self rowsInRect:clipRect];
	float yToDraw = -0.5;
	float ySpacing = [self rowHeight] + [self intercellSpacing].height;
	float rowRectOrigin = ySpacing * rangeOfRows.location;
	
	for (i = rangeOfRows.location; i < rangeOfRows.location + rangeOfRows.length; i++) {
		//don't draw this line if it's next to a selected row, or the row after it is being edited
		if (![set containsIndex:i] && editedRow != (NSInteger)(i+1)) {			
			yToDraw = rowRectOrigin + ySpacing - 0.5;
			[line moveToPoint:NSMakePoint(clipRect.origin.x, yToDraw)];
			[line lineToPoint:NSMakePoint(clipRect.origin.x + clipRect.size.width, yToDraw)];
		}
		rowRectOrigin += ySpacing;
	}
	//draw everything after the visible range of rows
	while (rowRectOrigin < clipRect.size.height) {
		rowRectOrigin += ySpacing;
		[line moveToPoint:NSMakePoint(clipRect.origin.x, rowRectOrigin)];
		[line lineToPoint:NSMakePoint(clipRect.origin.x + clipRect.size.width, rowRectOrigin)];
	}
	[line stroke];
	[NSGraphicsContext restoreGraphicsState];
}

- (void)_configureAttributesForCurrentLayout {
	BOOL horiz = [globalPrefs horizontalLayout];
	
	NoteAttributeColumn *col = [self noteAttributeColumnForIdentifier:NoteTitleColumnString];
	if (!cachedCell) cachedCell = [[col dataCell] retain];
	[col setDataCell: horiz ? [[[UnifiedCell alloc] init] autorelease] : cachedCell];
	
	NSFont *font = [NSFont systemFontOfSize:[globalPrefs tableFontSize]];
	NSUInteger i;
	for (i=0; i<[allColumns count]; i++) {
		[[[allColumns objectAtIndex:i] dataCell] setFont:font];
	}	
	BOOL isOneRow = !horiz || (![globalPrefs tableColumnsShowPreview] && !ColumnIsSet(NoteLabelsColumn, [globalPrefs tableColumnsBitmap]));
	
	if (IsLeopardOrLater)
		[self setSelectionHighlightStyle:isOneRow ? NSTableViewSelectionHighlightStyleRegular : NSTableViewSelectionHighlightStyleSourceList];
	
	NSLayoutManager *lm = [[NSLayoutManager alloc] init];
	tableFontHeight = [lm defaultLineHeightForFont:font];
	float h[4] = {(tableFontHeight * 3.0 + 5.0f), (tableFontHeight * 2.0 + 6.0f), (tableFontHeight + 2.0f), tableFontHeight + 2.0f};
	[self setRowHeight: horiz ? ([globalPrefs tableColumnsShowPreview] ? h[0] : 
								 (ColumnIsSet(NoteLabelsColumn,[globalPrefs tableColumnsBitmap]) ? h[1] : h[2])) : h[3]];
	[lm release];
	
	[self setIntercellSpacing:NSMakeSize(12, 2)];
	
	//[self setGridStyleMask:horiz ? NSTableViewSolidHorizontalGridLineMask : NSTableViewGridNone];
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
	
	if ([selectorString isEqualToString:SEL_STR(setTableFontSize:sender:)]) {
		
		[self _configureAttributesForCurrentLayout];
		
	} else if ([selectorString isEqualToString:SEL_STR(setHorizontalLayout:sender:)]) {
		
		[self abortEditing];
		
		//restore columns according to the current preferences
		
		[self restoreColumns];
		[self updateHeaderViewForColumns];
		
		[self _configureAttributesForCurrentLayout];
		
		[self updateTitleDereferencorState];
		
		viewMenusValid = NO;
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
	NSInteger colIndex = -1;
	NSInteger selected = [self selectedRow];
	
	if (selected < 0) {
		NSBeep();
		return;
	}
	
	if ([globalPrefs horizontalLayout]) {
		
		//default to editing title if this is attempted in horizontal mode for any column other than tags
		//(which currently are the only two editable columns, anyway)
		colIndex = [identifier isEqualToString:NoteLabelsColumnString] ? SYNTHETIC_TAGS_COLUMN_INDEX : 0;
	} else if ((colIndex = [self columnWithIdentifier:identifier]) < 0) {
		//always move title column to 0 index
		NSInteger newColIndex = (NSInteger)(![identifier isEqualToString:NoteTitleColumnString]);
		
		NSTableColumn *column = [self noteAttributeColumnForIdentifier:identifier];
		if (column && [self addPermanentTableColumn:column]) {
			
			NSUInteger addedColIndex = [[self tableColumns] indexOfObjectIdenticalTo:column];
			if (addedColIndex < [[self tableColumns] count]) {
				[self moveColumn:addedColIndex toColumn:newColIndex];
				colIndex = newColIndex;
				[self sizeToFit];
			}
		}
	}
	
	if (colIndex > -1) {
		[self editColumn:colIndex row:selected withEvent:[[self window] currentEvent] select:YES];
	} else {
		NSBeep();
	}
}

- (NoteAttributeColumn*)noteAttributeColumnForIdentifier:(NSString*)identifier {
	return [allColsDict objectForKey:identifier];
}

- (BOOL)addPermanentTableColumn:(NSTableColumn*)column {
	if (![globalPrefs horizontalLayout]) {
		[self addTableColumn:column];
	}
	[globalPrefs addTableColumn:[column identifier] sender:self];
	
	if ([globalPrefs horizontalLayout]) //for now, for extending rowheight when tags are shown/hidden
		[self _configureAttributesForCurrentLayout];
	
	if ([[column identifier] isEqualToString:[globalPrefs sortedTableColumnKey]]) {
		[(NoteAttributeColumn*)[self highlightedTableColumn] updateWidthForHighlight];
		[self setHighlightedTableColumn:column];
		[(NoteAttributeColumn*)column updateWidthForHighlight];
	}
	
	[self updateHeaderViewForColumns];
	
	viewMenusValid = NO;
	return YES;
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
	
	if ([globalPrefs horizontalLayout] && [[column identifier] isEqualToString:NoteTitleColumnString]) {
		NSBeep();
		return;
	}
	
    if ([[globalPrefs visibleTableColumns] containsObject:[column identifier]]) {
		
		if ([[globalPrefs visibleTableColumns] count] > 1) {
			[self abortEditing];
			[self removeTableColumn:column];
			[globalPrefs removeTableColumn:[column identifier] sender:self];
			viewMenusValid = NO;
			if ([globalPrefs horizontalLayout]) //for now, in case we are hiding tags when previews are not visible
				[self _configureAttributesForCurrentLayout];
		} else {
			NSBeep();
		}
		
		[self updateHeaderViewForColumns];
		
    } else {
		[self addPermanentTableColumn:column];
		
		NSArray *cols = [self tableColumns];
		
		NSUInteger addedColIndex = [cols indexOfObjectIdenticalTo:column];
		NSInteger clickedColIndex = [sender tag];
		
		if ((NSUInteger)clickedColIndex < [cols count] && addedColIndex < [cols count])
			[self moveColumn:addedColIndex toColumn:clickedColIndex + 1];
    }
    
    [self sizeToFit];
}

- (IBAction)toggleNoteBodyPreviews:(id)sender {
	[globalPrefs setTableColumnsShowPreview: ![globalPrefs tableColumnsShowPreview] sender:self];
	[self _configureAttributesForCurrentLayout];
    [self setNeedsDisplay:YES];
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
    
	NSArray *prefsCols = [globalPrefs visibleTableColumns];
	
    NSEnumerator *theEnumerator = [allColumns objectEnumerator];
    NSTableColumn *theColumn = nil;
    while ((theColumn = [theEnumerator nextObject]) != nil) {
		NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:[[theColumn headerCell] stringValue] 
															  action:@selector(actionHideShowColumn:) 
													   keyEquivalent:@""] autorelease];
		[theMenuItem setTarget:self];
		[theMenuItem setRepresentedObject:theColumn];
		[theMenuItem setState:[prefsCols containsObject:[theColumn identifier]]];
		[theMenuItem setTag:(inSelectedColumn ? [[self tableColumns] indexOfObjectIdenticalTo:inSelectedColumn] : 0)];
		
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

static void _CopyItemWithSelectorFromMenu(NSMenu *destMenu, NSMenu *sourceMenu, SEL aSel, id target, NSInteger tag) {
	NSInteger idx = [sourceMenu indexOfItemWithTag:tag];
	if (idx > -1 || (idx = [sourceMenu indexOfItemWithTarget:target andAction:aSel]) > -1) {
		[destMenu addItem:[[(NSMenuItem*)[sourceMenu itemAtIndex:idx] copy] autorelease]];
	}
}

- (NSMenu *)defaultNoteCommandsMenuWithTarget:(id)target {
	NSMenu *theMenu = [[[NSMenu alloc] initWithTitle:@"Contextual Note Commands Menu"] autorelease];
	NSMenu *notesMenu = [[[NSApp mainMenu] itemWithTag:NOTES_MENU_ID] submenu];
	
	_CopyItemWithSelectorFromMenu(theMenu, notesMenu, @selector(renameNote:), target, -1);
	_CopyItemWithSelectorFromMenu(theMenu, notesMenu, @selector(tagNote:), target, -1);
	_CopyItemWithSelectorFromMenu(theMenu, notesMenu, @selector(deleteNote:), target, -1);
	
	[theMenu addItem:[NSMenuItem separatorItem]];
	
	NSMenuItem *noteLinkItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Copy URL",@"contextual menu item title to copy urls")
														  action:@selector(copyNoteLink:) keyEquivalent:@"c"];
	[noteLinkItem setKeyEquivalentModifierMask:NSCommandKeyMask|NSAlternateKeyMask];
	[noteLinkItem setTarget:target];
	[theMenu addItem:[noteLinkItem autorelease]];
	
	_CopyItemWithSelectorFromMenu(theMenu, notesMenu, @selector(exportNote:), target, -1);
	_CopyItemWithSelectorFromMenu(theMenu, notesMenu, @selector(revealNote:), target, -1);
	_CopyItemWithSelectorFromMenu(theMenu, notesMenu, NULL, target, 88);
	
	[theMenu setSubmenu:[[ExternalEditorListController sharedInstance] addEditNotesMenu] forItem:[theMenu itemAtIndex:[theMenu numberOfItems] - 1]];
	
	[theMenu addItem:[NSMenuItem separatorItem]];
	
	_CopyItemWithSelectorFromMenu(theMenu, notesMenu, @selector(printNote:), target, -1);
	
	NSArray *notes = [(FastListDataSource*)[self dataSource] objectsAtFilteredIndexes:[self selectedRowIndexes]];
	[notes addMenuItemsForURLsInNotes:theMenu];
	
	return theMenu;
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
    if ([event clickCount]==1) {
        [[self delegate] setIsEditing:NO];
    }
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
    
    [[NSApp delegate] resetModTimers];
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
	} else{
		[super keyDown:theEvent];
    }
        
    
}



enum { kNext_Tag = 'j', kPrev_Tag = 'k' };

//use this method to catch next note/prev note before View menu does
//thus avoiding annoying flicker and slow-down
- (BOOL)performKeyEquivalent:(NSEvent *)theEvent {
   [[NSApp delegate] resetModTimers];
	unsigned mods = [theEvent modifierFlags];
	
	BOOL isControlKeyPressed = (mods & NSControlKeyMask) != 0 && [userDefaults boolForKey: @"UseCtrlForSwitchingNotes"];
	BOOL isCommandKeyPressed = (mods & NSCommandKeyMask) != 0;

	// Also catch Ctrl-J/-K to match the shortcuts of other apps
	if ((isControlKeyPressed || isCommandKeyPressed) && ((mods & NSShiftKeyMask) == 0)) {
		
		unichar keyChar = ' '; 
		if (isCommandKeyPressed) {
			keyChar = [theEvent firstCharacter]; /*cannot use ignoringModifiers here as it subverts the Dvorak-Qwerty-CMD keyboard layout */
		}
		if (isControlKeyPressed) {
			keyChar = [theEvent firstCharacterIgnoringModifiers]; /* first gets '\n' when control key is set, so fall back to ignoringModifiers */
		}
		
		// Handle J and K for both Control and Command
		if ( keyChar == kNext_Tag || keyChar == kPrev_Tag ) {
			if (mods & NSAlternateKeyMask) {
				[self selectRowAndScroll:((keyChar == kNext_Tag) ? [self numberOfRows] - 1 :  0)];
			} else {
				[self _incrementNoteSelectionByTag:keyChar];
			}
			return YES;
		}

		// Handle N and P, but only when Control is pressed
		if ( (keyChar == 'n' || keyChar == 'p') && (!isCommandKeyPressed)) {
			// Determine if the note editing pane is selected:
			if (![[[self window] firstResponder] isKindOfClass:[LinkingEditor class]]) {
				[self _incrementNoteSelectionByTag:(keyChar == 'n') ? kNext_Tag : kPrev_Tag];
				return YES;
			}
		}

		// Make Control-[ equivalent to Escape
		if ( (keyChar == '[' ) && (!isCommandKeyPressed)) {
			[self cancelOperation:nil];
			return YES;
		}
	}
	
	return [super performKeyEquivalent:theEvent];
}

- (void)_incrementNoteSelectionByTag:(NSInteger)tag {
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

- (void)incrementNoteSelection:(id)sender {
	[self _incrementNoteSelectionByTag:[sender tag]];
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
	} else if (command == @selector(insertTab:)) {
		
		if ([globalPrefs horizontalLayout] && !lastEventActivatedTagEdit && ColumnIsSet(NoteLabelsColumn, [globalPrefs tableColumnsBitmap])) {
			//if we're currently renaming a note in horizontal mode, then tab should move focus to tags area
			
			[self editRowAtColumnWithIdentifier:NoteLabelsColumnString];
			return YES;
		}else{
            [[self delegate] setIsEditing:NO];
        }
	} else if (command == @selector(insertBacktab:)) {
		
		if ([globalPrefs horizontalLayout] && lastEventActivatedTagEdit) {
			//if we're currently tagging a note in horizontal mode, then tab should move focus to renaming
			
			[self editRowAtColumnWithIdentifier:NoteTitleColumnString];
			return YES;
		}else{
            [[self delegate] setIsEditing:NO];
        }
	}else if (command == @selector(insertNewline:)) {
        [[self delegate] setIsEditing:NO];
    }
	
	return NO;
}

- (BOOL)textView:(NSTextView *)aTextView shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString {
	wasDeleting = ![replacementString length];
	return YES;
}

- (id)labelsListSource {
	return labelsListSource;
}

- (void)setLabelsListSource:(id)labelsSource {
	labelsListSource = labelsSource;
}

- (NSArray *)textView:(NSTextView *)aTextView completions:(NSArray *)words  forPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger *)anIndex {

	if (charRange.location != NSNotFound) {
		if (!IsLeopardOrLater)
			goto getCompletions;
		
		NSCharacterSet *set = [NSCharacterSet labelSeparatorCharacterSet];
		NSString *str = [aTextView string];
#define CharIndexIsMember(__index) ([set characterIsMember:[str characterAtIndex:(__index)]])
		
		BOOL hasLChar = charRange.location > 0;
		BOOL hasRChar = NSMaxRange(charRange) < [str length];
		
		//suggest tags only if the suggestion-range borders a tag-separating character; if at the end/beginning of a string, check the other side
		if (NSEqualRanges(charRange, NSMakeRange(0, [str length])) || 
			(hasLChar && hasRChar && CharIndexIsMember(charRange.location - 1) && CharIndexIsMember(NSMaxRange(charRange))) ||
			(hasLChar && NSMaxRange(charRange) == [str length] && CharIndexIsMember(charRange.location - 1)) ||
			(hasRChar && charRange.location == 0 && CharIndexIsMember(NSMaxRange(charRange)))) {
			
		getCompletions:
			{
			NSSet *existingWordSet = [NSSet setWithArray:[[aTextView string] labelCompatibleWords]];
			NSArray *tags = [labelsListSource labelTitlesPrefixedByString:[[aTextView string] substringWithRange:charRange] 
													  indexOfSelectedItem:anIndex minusWordSet:existingWordSet];
			return tags;
			}
		}
	}
	return [NSArray array];
}


- (BOOL)eventIsTagEdit:(NSEvent*)event forColumn:(NSInteger)columnIndex row:(NSInteger)rowIndex {
	//is it a mouse event? is it within the tags area?
	//is it a keyboard event? is it command-shift-t?
	
	if (![globalPrefs horizontalLayout])
		return NO;
	
	NSEventType type = [event type];
	if (type == NSLeftMouseDown || type == NSLeftMouseUp) {
		
		NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
		
		//mouse is inside this column's row's cell's tags frame
		UnifiedCell *cell = [[[self tableColumns] objectAtIndex:columnIndex] dataCellForRow:rowIndex];
		NSRect tagCellRect = [cell nv_tagsRectForFrame:[self frameOfCellAtColumn:columnIndex row:rowIndex]];
		
		return [self mouse:p inRect:tagCellRect];
		
	} else if (type == NSKeyDown) {
		
		//activated either using the shortcut or using tab, when there was already an editor, and the last event invoked rename
		//checking for the keyboard equivalent here is redundant in theory
		
		return ([event firstCharacter] == 't' && ([event modifierFlags] & (NSShiftKeyMask | NSCommandKeyMask)) != 0) || 
		([event firstCharacter] == NSTabCharacter && !lastEventActivatedTagEdit && [self currentEditor]);
	}
	
	return NO;
}

- (SEL)attributeSetterForColumn:(NoteAttributeColumn*)col {
	if ([globalPrefs horizontalLayout] && [self columnWithIdentifier:[col identifier]] == 0) {
		return lastEventActivatedTagEdit ? @selector(setLabelString:) : @selector(setTitleString:);
	}
	return columnAttributeMutator(col);
}

- (BOOL)lastEventActivatedTagEdit {
	return lastEventActivatedTagEdit;
}

- (void)editColumn:(NSInteger)columnIndex row:(NSInteger)rowIndex withEvent:(NSEvent *)event select:(BOOL)flag {
    
    [[self delegate] setIsEditing:YES];
	BOOL isTitleCol = [self columnWithIdentifier:NoteTitleColumnString] == columnIndex;
	
	//if event's mouselocation is inside rowIndex cell's tag rect and this edit is in horizontal mode in the title column
	BOOL tagsInTitleColumn = [globalPrefs horizontalLayout] && ((isTitleCol && [self eventIsTagEdit:event forColumn:columnIndex row:rowIndex]) ||
																SYNTHETIC_TAGS_COLUMN_INDEX == columnIndex);
	
	if ([self editedRow] == rowIndex && [self currentEditor]) {
		//this row is currently being edited; finish editing before start it again anywhere else
		[[self window] makeFirstResponder:self];
	}
	lastEventActivatedTagEdit = tagsInTitleColumn;
	
	if (tagsInTitleColumn && !ColumnIsSet(NoteLabelsColumn, [globalPrefs tableColumnsBitmap])) {
		[self addPermanentTableColumn:[self noteAttributeColumnForIdentifier:NoteLabelsColumnString]];
	}
	
	[super editColumn:tagsInTitleColumn ? 0 : columnIndex row:rowIndex withEvent:event select:flag];
	
	//become/resignFirstResponder can't handle the field-editor case for row-highlighting style, so do it here:
	[self updateTitleDereferencorState];
	
	//this is way easier and faster than a custom formatter! just change the title while we're editing!
	if (isTitleCol || tagsInTitleColumn) {
		NoteObject *note = [(FastListDataSource*)[self dataSource] immutableObjects][rowIndex];
		
		NSTextView *editor = (NSTextView*)[self currentEditor];
		[editor setString: tagsInTitleColumn ? labelsOfNote(note) : titleOfNote(note)];
		
		NSRange range = NSMakeRange(0, [[editor string] length]);
#if 0
		NoteAttributeColumn *col = [self noteAttributeColumnForIdentifier:NoteTitleColumnString];
		if (tagsInTitleColumn && dereferencingFunction(col) != unifiedCellSingleLineForNote) {
			//the textview will comply! when editing tags, use a smaller font, right-aligned
			[editor setAlignment:NSRightTextAlignment range:range];
			NSFont *smallerFont = [NSFont systemFontOfSize:[globalPrefs tableFontSize] - 1.0];
			[editor setFont:smallerFont range:range];
			NSMutableParagraphStyle *pstyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
			[pstyle setAlignment:NSRightTextAlignment];
			[editor setTypingAttributes:[NSDictionary dictionaryWithObjectsAndKeys:pstyle, NSParagraphStyleAttributeName, smallerFont, NSFontAttributeName, nil]];
		}
#endif
		
		if (flag) [editor setSelectedRange:range];
	}	
}

- (void)textDidEndEditing:(NSNotification *)aNotification {
	[super textDidEndEditing:aNotification];
	[self updateTitleDereferencorState];
}


- (BOOL)abortEditing {
    [[self delegate] setIsEditing:NO];
	BOOL result = [super abortEditing];
	[self updateTitleDereferencorState];
	return result;
}

- (void)cancelOperation:(id)sender {
	[self abortEditing];
	[[NSApp delegate] cancelOperation:sender];
}

- (void)textDidChange:(NSNotification *)aNotification {
	NSInteger col = [self editedColumn];
	if (col > -1 && [self attributeSetterForColumn:[[self tableColumns] objectAtIndex:col]] == @selector(setLabelString:)) {
		//text changed while editing tags; autocomplete!
		
		NSTextView *editor = [aNotification object];
		
		//NSLog(@"isAutocompleting: %d, wasDeleting: %d", isAutocompleting, wasDeleting);
		if (!isAutocompleting && !wasDeleting) {
			isAutocompleting = YES;
			[editor complete:self];
			isAutocompleting = NO;
		}
	}
}

- (NSArray *)labelCompletionsForString:(NSString *)fieldString index:(int)index{
    NSRange charRange = [fieldString rangeOfString:fieldString];
    NSArray *tags = [NSArray arrayWithObject:@""];
    if (charRange.location != NSNotFound) {
		if (!IsLeopardOrLater)
			goto getCompletions;
		
		NSCharacterSet *set = [NSCharacterSet labelSeparatorCharacterSet];
		NSString *str = fieldString;
#define CharIndexIsMember(__index) ([set characterIsMember:[str characterAtIndex:(__index)]])
		
		BOOL hasLChar = charRange.location > 0;
		BOOL hasRChar = NSMaxRange(charRange) < [str length];
		
		//suggest tags only if the suggestion-range borders a tag-separating character; if at the end/beginning of a string, check the other side
		if (NSEqualRanges(charRange, NSMakeRange(0, [str length])) || 
			(hasLChar && hasRChar && CharIndexIsMember(charRange.location - 1) && CharIndexIsMember(NSMaxRange(charRange))) ||
			(hasLChar && NSMaxRange(charRange) == [str length] && CharIndexIsMember(charRange.location - 1)) ||
			(hasRChar && charRange.location == 0 && CharIndexIsMember(NSMaxRange(charRange)))) {
			
		getCompletions:
			{
				NSSet *existingWordSet = [NSSet setWithArray:[fieldString labelCompatibleWords]];
				tags = [labelsListSource labelTitlesPrefixedByString:[fieldString substringWithRange:charRange] 
														  indexOfSelectedItem:index minusWordSet:existingWordSet];
				
                //NSLog(@"tags is :%@",[tags description]);
			}
		}
	}
    return tags;
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
	if(([globalPrefs showGrid])||(([globalPrefs horizontalLayout])&&(![globalPrefs alternatingRows]))){
        [self setGridStyleMask:NSTableViewSolidHorizontalGridLineMask];
    }else{
        [self setGridStyleMask:NSTableViewGridNone];
    }
    //force fully live resizing of columns while resizing window
    [super drawRect:rect];
	
	if (![self dataSource]) {
		NSSize size = [self bounds].size;
		
		BOOL didRotate = NO;
		NSPoint center = NSMakePoint(size.width / 2.0, size.height / 2.0);
		if ((didRotate = loadStatusStringWidth + 10.0 > size.width)) {
			
			NSAffineTransform *translateTransform = [NSAffineTransform transform];
			[translateTransform translateXBy:center.x yBy:center.y];
			[translateTransform rotateByDegrees:90.0];
			[translateTransform translateXBy:-center.x yBy:-center.y];
			[NSGraphicsContext saveGraphicsState];
			[translateTransform concat];
		}
		
		[loadStatusString drawAtPoint:NSMakePoint(center.x - loadStatusStringWidth/2.0, center.y - STATUS_STRING_FONT_SIZE/2.0) 
					   withAttributes:loadStatusAttributes];
		
		if (didRotate) [NSGraphicsContext restoreGraphicsState];
	}
}

# pragma mark elasticthreads work
- (void)flagsChanged:(NSEvent *)theEvent{
	[[NSApp delegate] flagsChanged:theEvent];
}

- (void)setBackgroundColor:(NSColor *)color{
    [super setBackgroundColor:color];
    [NotesTableHeaderCell setBackgroundColor:color];
    CGFloat fWhite;		
    fWhite = [[color colorUsingColorSpaceName:NSCalibratedWhiteColorSpace] whiteComponent];
    if (fWhite < 0.75f) {
        if (fWhite<0.25f) {
            fWhite += 0.22f;
        }else {
            fWhite += 0.16f;
        }		
    }else {
        fWhite -= 0.20f;
    }
    [self setGridColor:[NSColor colorWithCalibratedWhite:fWhite alpha:1.0f]];
   
}

# pragma mark alternating rows (Brett)
- (void)highlightSelectionInClipRect:(NSRect)clipRect
{
	CGFloat fWhite;
	CGFloat endWhite;
	CGFloat fAlpha;
	NSColor *backgroundColor = [[self delegate] backgrndColor];
    
	NSColor	*gBack = [backgroundColor colorUsingColorSpaceName:NSCalibratedWhiteColorSpace];
	NSColor *evenColor = backgroundColor;
	NSColor *oddColor = backgroundColor;
	[gBack getWhite:&fWhite alpha:&fAlpha];
	if ([globalPrefs alternatingRows]) {
		if (fWhite < 0.5f) {
			endWhite = fWhite + 0.25f;
			oddColor = [backgroundColor blendedColorWithFraction:0.05f ofColor:[NSColor whiteColor]];
		} else {
			endWhite = fWhite-0.28f;
			oddColor = [backgroundColor blendedColorWithFraction:0.05f ofColor:[NSColor blackColor]];
		}
	}
	float rowHeight = [self rowHeight] + [self intercellSpacing].height;
	NSRect visibleRect = [self visibleRect];
	NSRect highlightRect;
	
	highlightRect.origin = NSMakePoint(
									   NSMinX(visibleRect),
									   (int)(NSMinY(clipRect)/rowHeight)*rowHeight);
	highlightRect.size = NSMakeSize(
									NSWidth(visibleRect),
									rowHeight - [self intercellSpacing].height);
	
	while (NSMinY(highlightRect) < NSMaxY(clipRect))
	{
		NSRect clippedHighlightRect
		= NSIntersectionRect(highlightRect, clipRect);
		int row = (int)
		((NSMinY(highlightRect)+rowHeight/2.0)/rowHeight);
		NSColor *rowColor = (0 == row % 2) ? evenColor : oddColor;
		[rowColor set];
		NSRectFill(clippedHighlightRect);
		highlightRect.origin.y += rowHeight;
	}
    
	[super highlightSelectionInClipRect: clipRect];
}

@end
