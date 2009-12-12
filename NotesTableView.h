/* NotesTableView */

#import <Cocoa/Cocoa.h>

@class HeaderViewWithMenu;
@class NoteAttributeColumn;
@class GlobalPrefs;

#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_4

typedef enum { 
	NSTableViewNoColumnAutoresizing = 0,
	NSTableViewUniformColumnAutoresizingStyle,
	NSTableViewSequentialColumnAutoresizingStyle,
	NSTableViewReverseSequentialColumnAutoresizingStyle,
	NSTableViewLastColumnOnlyAutoresizingStyle,
	NSTableViewFirstColumnOnlyAutoresizingStyle
} NSTableViewColumnAutoresizingStyle;

@interface NSTableView (TigerAdditions)
-(void)setColumnAutoresizingStyle:(NSTableViewColumnAutoresizingStyle)style;
@end

#endif

typedef struct _ViewLocationContext {
	BOOL pivotRowWasEdge;
	id nonRetainedPivotObject;
	float verticalDistanceToPivotRow;
} ViewLocationContext;


@interface NotesTableView : NSTableView {
	IBOutlet NSTextField *controlField;
	NSMutableArray *allColumns;
	
	NSInteger firstRowIndexBeforeSplitResize;
	
	BOOL viewMenusValid;
	BOOL hadHighlightInForeground, hadHighlightInBackground;
	BOOL shouldUseSecondaryHighlightColor;
		
	GlobalPrefs *globalPrefs;
	NSMenuItem *dummyItem;
	HeaderViewWithMenu *headerView;
	NSView *cornerView;
	
	NSDictionary *loadStatusAttributes;
	float loadStatusStringWidth;
	NSString *loadStatusString;

	int affinity;	
}

- (void)noteFirstVisibleRow;
- (void)makeFirstPreviouslyVisibleRowVisibleIfNecessary;

- (ViewLocationContext)viewingLocation;
- (void)setViewingLocation:(ViewLocationContext)ctx;
- (void)scrollRowToVisible:(NSInteger)rowIndex withVerticalOffset:(float)offset;
- (void)selectRowAndScroll:(NSInteger)row;

- (void)setShouldUseSecondaryHighlightColor:(BOOL)value;

- (void)restoreColumns;

- (void)updateHeaderViewForColumns;
- (void)editRowAtColumnWithIdentifier:(id)identifier;
- (void)addPermanentTableColumn:(NSTableColumn*)column;
- (IBAction)actionHideShowColumn:(id)sender;
- (IBAction)toggleNoteBodyPreviews:(id)sender;
- (void)setStatusForSortedColumn:(id)item;
- (void)setSortDirection:(BOOL)direction inTableColumn:(NSTableColumn*)tableColumn;
- (NSMenu *)defaultNoteCommandsMenuWithTarget:(id)target;
- (NSMenu *)menuForColumnSorting;
- (NSMenu *)menuForColumnConfiguration:(NSTableColumn *)inSelectedColumn;
- (NoteAttributeColumn*)noteAttributeColumnForIdentifier:(NSString*)identifier;

- (void)incrementNoteSelection:(id)sender;

@end

@interface NSTableView (Private)
- (BOOL)_shouldUseSecondaryHighlightColor;
- (void)_sizeRowHeaderToFitIfNecessary;

//10.3 only
- (void)_sizeToFitIfNecessary;
@end
