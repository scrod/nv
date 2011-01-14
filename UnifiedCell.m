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


#import "UnifiedCell.h"
#import "NoteObject.h"
#import "NotesTableView.h"
#import "GlobalPrefs.h"
#import "NSString_CustomTruncation.h"

@implementation UnifiedCell

- (id)init {
	if ([super init]) {

		//should be handled by NSParagraphStyle in our string, as it is more complex than this
//		[self setLineBreakMode:NSLineBreakByTruncatingTail];
		if (IsLeopardOrLater)
			[self setTruncatesLastVisibleLine:YES];
		[self setEditable:YES];
	}
	return self;
}

- (void)dealloc {
	[super dealloc];
}

- (void)selectWithFrame:(NSRect)aRect inView:(NSView *)controlView editor:(NSText *)textObj 
			   delegate:(id)anObject start:(NSInteger)selStart length:(NSInteger)selLength {
	
	NSLog(@"selectwithframe: %@, view: %@, editor: %@, len: %d", NSStringFromRect(aRect), controlView, textObj, selLength);
	[super selectWithFrame:aRect inView:controlView editor:textObj delegate:anObject start:selStart length:selLength];
}


- (NoteObject*)noteObject {
	return noteObject;
}

- (void)setNoteObject:(NoteObject*)obj {
	[noteObject autorelease];
	noteObject = [obj retain];
}

- (void)setPreviewIsHidden:(BOOL)value {
	previewIsHidden = value;
}

- (NSMutableDictionary*)baseTextAttributes {
	static NSMutableParagraphStyle *alignStyle = nil;
	if (!alignStyle) {
		alignStyle = [[NSMutableParagraphStyle alloc] init];
		[alignStyle setAlignment:NSRightTextAlignment];
	}
	return [NSMutableDictionary dictionaryWithObjectsAndKeys:alignStyle, NSParagraphStyleAttributeName, [self font], NSFontAttributeName, nil];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {	

	[super drawWithFrame:cellFrame inView:controlView];	
	
	//draw note date and tags
	
	NotesTableView *tv = (NotesTableView *)controlView;

	NSMutableDictionary *baseAttrs = [self baseTextAttributes];
	BOOL isActive = (IsLeopardOrLater && [tv selectionHighlightStyle] == NSTableViewSelectionHighlightStyleSourceList) ? YES : [tv isActiveStyle];
	
	if ([self isHighlighted] && isActive) {
		[baseAttrs setObject:[NSColor whiteColor] forKey:NSForegroundColorAttributeName];
	} else if (![self isHighlighted]) {
		[baseAttrs setObject:[NSColor grayColor] forKey:NSForegroundColorAttributeName];
	}
	
	//if the sort-order is date-created, then show the date on which this note was created; otherwise show date modified.
	BOOL isSortedByDateCreated = [[[GlobalPrefs defaultPrefs] sortedTableColumnKey] isEqualToString:NoteDateCreatedColumnString];
	id (*dateReferencor)(id, id, NSInteger) = isSortedByDateCreated ? dateCreatedStringOfNote : dateModifiedStringOfNote;
	NSString *dateStr = dateReferencor(tv, noteObject, NSNotFound);
	
	float fontHeight = [tv tableFontHeight];
	
	[dateStr drawInRect:NSMakeRect(NSMaxX(cellFrame) - 70.0, NSMinY(cellFrame), 70.0, fontHeight) withAttributes:baseAttrs];
	
	NSString *labelStr = labelsOfNote(noteObject);
	if ([labelStr length])
		[labelStr drawInRect:NSMakeRect(previewIsHidden ? NSMinX(cellFrame) : NSMaxX(cellFrame) - 70.0, 
										NSMaxY(cellFrame) - (fontHeight + 3.0), 70.0, fontHeight) withAttributes:baseAttrs];
}

@end
