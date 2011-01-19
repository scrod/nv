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
#import "NSBezierPath_NV.h"
#import "NSString_CustomTruncation.h"
#import "NoteAttributeColumn.h"

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

#if 0
//changes will hereafter affect all field editors for the window; do not want
- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
	NSTextView *tv = (NSTextView *)[super setUpFieldEditorAttributes:textObj];
	
	[tv setTextContainerInset:NSMakeSize(-2,-2)];
	
	NSTextContainer *tc = [tv textContainer];
	[tc setContainerSize:NSMakeSize(1.0e7, 1.0e7)];
	[tc setWidthTracksTextView:NO];
	[tc setHeightTracksTextView:NO];
	
	[tv setMinSize:[tv frame].size];
    [tv setMaxSize:NSMakeSize(1.0e7, [tv frame].size.height)];
    [tv setHorizontallyResizable:YES];
    [tv setVerticallyResizable:NO];
    [tv setAutoresizingMask:NSViewNotSizable];
	return tv;
}
#endif

- (void)selectWithFrame:(NSRect)aRect inView:(NSView *)controlView editor:(NSText *)textObj 
			   delegate:(id)anObject start:(NSInteger)selStart length:(NSInteger)selLength {
	
	NSRect rect = [(NotesTableView*)controlView lastEventActivatedTagEdit] ? [self nv_tagsRectForFrame:aRect andImage:nil] : [self nv_titleRectForFrame:aRect];
	[super selectWithFrame:rect inView:controlView editor:textObj delegate:anObject start:selStart length:selLength];
	
	[controlView setKeyboardFocusRingNeedsDisplayInRect:NSInsetRect([self nv_tagsRectForFrame:aRect andImage:nil], -3, -3)];
}

- (NSFocusRingType)focusRingType {
	return NSFocusRingTypeNone;
}

- (float)tableFontFrameHeight {
	return [(NotesTableView*)[self controlView] tableFontHeight] + 1.0f;
}

- (NSRect)nv_titleRectForFrame:(NSRect)aFrame {
	//fixed based on width of the cell

	//height could justifiably vary based on wrapped height of title string
	return NSMakeRect(aFrame.origin.x, aFrame.origin.y, aFrame.size.width, [self tableFontFrameHeight]);
}

- (NSRect)nv_tagsRectForFrame:(NSRect)frame andImage:(NSImage*)img {
	//if no tags, return a default small frame to allow adding them
	float fontHeight = [self tableFontFrameHeight];
	NSSize size = img ? [img size] : NSMakeSize(NSWidth(frame), fontHeight);
	
	NSPoint pos = NSMakePoint((previewIsHidden ? NSMinX(frame) + 3.0 : NSMaxX(frame) - size.width), 
							  (previewIsHidden ? NSMinY(frame) + fontHeight + size.height : NSMaxY(frame) - 3.0));
	if (!img) {
		pos.y -= fontHeight;
	}
	
	return (NSRect){pos, size};
}

//- (BOOL)isScrollable {
//	if ([self isHighlighted] && [(NotesTableView *)[self controlView] currentEditor]) {
//		return YES;
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

+ (NSColor*)dateColorForTint {
	static NSColor *color = nil;
	static NSControlTint lastTint = -1;
	
	NSControlTint tint = [NSColor currentControlTint];
	
	if (!color || lastTint != tint) {
		if (tint == NSBlueControlTint) {
			color = [NSColor colorWithCalibratedRed:0.31 green:.494 blue:0.765 alpha:1.0];
		} else if (tint == NSGraphiteControlTint) {
			color = [NSColor colorWithCalibratedRed:0.498 green:0.525 blue:0.573 alpha:1.0];
		} else {
			color = [NSColor grayColor];
		}
		lastTint = tint;
		[color retain];
	}
	return color;
}

static NSShadow* ShadowForSnowLeopard() {
	static NSShadow *sh = nil;
	if (!sh) {
		sh = [[NSShadow alloc] init];
		[sh setShadowOffset:NSMakeSize(0,-1)];
		[sh setShadowColor:[NSColor colorWithCalibratedWhite:0.15 alpha:0.67]];
		[sh setShadowBlurRadius:0.5];
	}
	return sh;
}

NSAttributedString *AttributedStringForSelection(NSAttributedString *str, BOOL withShadow) {
	//used to modify the cell's attributed string before display when it is selected
	
	//snow leopard is stricter about applying the default highlight-attributes (e.g., no shadow unless no paragraph formatting)
	//so add the shadow here for snow leopard on selected rows

	NSRange fullRange = NSMakeRange(0, [str length]);
	NSMutableAttributedString *colorFreeStr = [str mutableCopy];
	[colorFreeStr removeAttribute:NSForegroundColorAttributeName range:fullRange];
	if (withShadow) {
		[colorFreeStr addAttribute:NSShadowAttributeName value:ShadowForSnowLeopard() range:NSMakeRange(0, [str length])];
	}
	return [colorFreeStr autorelease];
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
	
	NSColor *textColor = ([self isHighlighted] && isActive) ? [NSColor whiteColor] : (![self isHighlighted] ? [[self class] dateColorForTint]/*[NSColor grayColor]*/ : nil);
	if (textColor)
		[baseAttrs setObject:textColor forKey:NSForegroundColorAttributeName];
	if (IsSnowLeopardOrLater && [self isHighlighted]) {
		[baseAttrs setObject:ShadowForSnowLeopard() forKey:NSShadowAttributeName];
	}
	
	//if the sort-order is date-created, then show the date on which this note was created; otherwise show date modified.
	BOOL isSortedByDateCreated = [[[GlobalPrefs defaultPrefs] sortedTableColumnKey] isEqualToString:NoteDateCreatedColumnString];
	id (*dateReferencor)(id, id, NSInteger) = isSortedByDateCreated ? dateCreatedStringOfNote : dateModifiedStringOfNote;
	NSString *dateStr = dateReferencor(tv, noteObject, NSNotFound);
	
	float fontHeight = [tv tableFontHeight];
	
	[dateStr drawInRect:NSMakeRect(NSMaxX(cellFrame) - 70.0, NSMinY(cellFrame), 70.0, fontHeight) withAttributes:baseAttrs];

	NSImage *img = ([self isHighlighted] && isActive) ? [noteObject labelsPreviewImageOfColor:[NSColor whiteColor]] : [noteObject labelsPreviewImage];
	
	if (img) {
		NSRect rect = [self nv_tagsRectForFrame:cellFrame andImage:img];
		rect = [controlView centerScanRect:rect];
		
		//clip the tags image within the bounds of the cell so that narrow columns look nicer
		[NSGraphicsContext saveGraphicsState];
		NSRectClip(cellFrame);
		
		[img compositeToPoint:rect.origin operation:NSCompositeSourceOver];
		
		[NSGraphicsContext restoreGraphicsState];
	}
	
	if ([tv currentEditor] && [self isHighlighted]) {
		//needed because the body text is normally not drawn while editing
		NSMutableAttributedString *cloneStr = [[self attributedStringValue] mutableCopy];
		[cloneStr addAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[self font], NSFontAttributeName, textColor, 
								 NSForegroundColorAttributeName, nil] range:NSMakeRange(0, [cloneStr length])];
		[cloneStr addAttributes:LineTruncAttributesForTitle() range:NSMakeRange(0, [titleOfNote(noteObject) length])];
		
		[cloneStr drawWithRect:NSInsetRect([self titleRectForBounds:cellFrame], 2., 0.) options: NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin];
		[cloneStr release];
		
		//draw a slightly different focus ring than what would have been drawn
		NSRect rect = [tv lastEventActivatedTagEdit] ? [self nv_tagsRectForFrame:cellFrame andImage:nil] : [self nv_titleRectForFrame:cellFrame];

		if ([tv lastEventActivatedTagEdit]) {
			rect = NSInsetRect(rect, -2, -1);
		} else {
			rect = NSInsetRect(rect, -2, -1);
		}
		
		[NSGraphicsContext saveGraphicsState];
		NSBezierPath *path = [NSBezierPath bezierPathWithRect:rect];
		
		//megafocusring casts a shadow both outside and inside
		if ([tv lastEventActivatedTagEdit]) {
		NSSetFocusRingStyle(NSFocusRingBelow);
		[path fill];
		}
		NSSetFocusRingStyle(NSFocusRingOnly);
		[path fill];

		[NSGraphicsContext restoreGraphicsState];
		
	}
}

@end
