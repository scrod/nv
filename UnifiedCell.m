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

	//aRect.size.height = [(NotesTableView*)[self controlView] tableFontHeight] + 2.0f;

	NSLog(@"selectwithframe: %@, view: %@, editor: %@, len: %d", NSStringFromRect(aRect), controlView, textObj, selLength);

	[super selectWithFrame:[self nv_titleRectForFrame:aRect] inView:controlView editor:textObj delegate:anObject start:selStart length:selLength];
}

- (NSFocusRingType)focusRingType {
	return NSFocusRingTypeNone;
}

- (NSRect)nv_titleRectForFrame:(NSRect)aFrame {
	//fixed based on width of the cell

	//high could justifiably vary based on wrapped height of title string
	return NSMakeRect(aFrame.origin.x, aFrame.origin.y, aFrame.size.width, [(NotesTableView*)[self controlView] tableFontHeight] + 2.0f);
}

- (NSRect)nv_tagsRectForFrame:(NSRect)frame andImage:(NSImage*)img {
	//if no tags, return a default small frame to allow adding them
	float fontHeight = [(NotesTableView*)[self controlView] tableFontHeight];
	NSSize size = img ? [img size] : NSMakeSize(30.0, fontHeight + 2.0f);
	
	NSPoint pos = NSMakePoint((previewIsHidden ? NSMinX(frame) : NSMaxX(frame) - size.width), 
							  (previewIsHidden ? NSMinY(frame) + fontHeight + size.height : NSMaxY(frame) - 3.0));
	
	return (NSRect){pos, size}; //NSMakeRect(pos.x, pos.y, [img size].width, [img size].height);
}

//- (BOOL)isScrollable {
//	if ([self isHighlighted] && [(NotesTableView *)[self controlView] currentEditor]) {
//		return NO;
//	}
//	return [super isScrollable];
//}

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
	
	NotesTableView *tv = (NotesTableView *)controlView;
	
	[super drawWithFrame:cellFrame inView:controlView];	
	
	//draw note date and tags

	NSMutableDictionary *baseAttrs = [self baseTextAttributes];
	BOOL isActive = (IsLeopardOrLater && [tv selectionHighlightStyle] == NSTableViewSelectionHighlightStyleSourceList) ? YES : [tv isActiveStyle];
	
	NSColor *textColor = ([self isHighlighted] && isActive) ? [NSColor whiteColor] : (![self isHighlighted] ? [NSColor colorForControlTint:[self controlTint]] : nil);
	[baseAttrs setObject:textColor forKey:NSForegroundColorAttributeName];
	
	//if the sort-order is date-created, then show the date on which this note was created; otherwise show date modified.
	BOOL isSortedByDateCreated = [[[GlobalPrefs defaultPrefs] sortedTableColumnKey] isEqualToString:NoteDateCreatedColumnString];
	id (*dateReferencor)(id, id, NSInteger) = isSortedByDateCreated ? dateCreatedStringOfNote : dateModifiedStringOfNote;
	NSString *dateStr = dateReferencor(tv, noteObject, NSNotFound);
	
	float fontHeight = [tv tableFontHeight];
	
	[dateStr drawInRect:NSMakeRect(NSMaxX(cellFrame) - 70.0, NSMinY(cellFrame), 70.0, fontHeight) withAttributes:baseAttrs];

	[noteObject updateLabelsPreviewImage];
	NSImage *img = ([self isHighlighted] && isActive) ? [noteObject labelsPreviewImageOfColor:[NSColor whiteColor]] : [noteObject labelsPreviewImage];
	
	if (img) {
		//[img compositeToPoint:NSMakePoint((previewIsHidden ? NSMinX(cellFrame) : NSMaxX(cellFrame) - [img size].width), 
//										  (previewIsHidden ? NSMinY(cellFrame) + fontHeight + [img size].height : NSMaxY(cellFrame) - 3.0)) operation:NSCompositeSourceOver];
		[img compositeToPoint:[self nv_tagsRectForFrame:cellFrame andImage:img].origin operation:NSCompositeSourceOver];
	}
#if 0
	NSString *labelStr = labelsOfNote(noteObject);
	if ([labelStr length]) {
		[labelStr drawInRect:NSMakeRect(previewIsHidden ? NSMinX(cellFrame) : NSMaxX(cellFrame) - 70.0, 
										NSMaxY(cellFrame) - (fontHeight + 3.0), 70.0, fontHeight) withAttributes:baseAttrs];
	}
#endif
	
	if ([tv currentEditor] && [self isHighlighted]) {
		NSMutableAttributedString *cloneStr = [[self attributedStringValue] mutableCopy];
		[cloneStr addAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[self font], NSFontAttributeName, textColor, NSForegroundColorAttributeName, nil] range:NSMakeRange(0, [cloneStr length])];
		
		[cloneStr drawWithRect:NSInsetRect([self titleRectForBounds:cellFrame], 2., 0.) options: NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin];
		[cloneStr release];
		
		
	}
}

@end
