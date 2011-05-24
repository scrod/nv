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


#import "DualField.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NSBezierPath_NV.h"
#import "LinearDividerShader.h"
#import "AppController.h"
#import "BookmarksController.h"

#define BORDER_TOP_OFFSET 3.0
#define BORDER_LEFT_OFFSET 3.0
#define MAX_STATE_IMG_DIM 16.0
#define CLEAR_BUTTON_IMG_DIM 16.0
#define TEXT_LEFT_OFFSET (MAX_STATE_IMG_DIM + BORDER_LEFT_OFFSET)

@implementation DualFieldCell

- (id) init {
	self = [super init];
	if (self != nil) {
		[self setStringValue:@""];
		[self setEditable:YES];
		[self setSelectable:YES];
		[self setBezeled:NO];
		[self setBordered:NO];
		[self setDrawsBackground:NO];
		[self setWraps:YES];
		[self setPlaceholderString:NSLocalizedString(@"Search or Create", @"placeholder text in search/create field")];
		
		[self setFocusRingType:NSFocusRingTypeExterior];
		
		clearButtonState = snapbackButtonState = BUTTON_HIDDEN;
		
	}
	return self;
}

- (NSRect)drawingRectForBounds:(NSRect)someBounds {
	return NSInsetRect(someBounds, TEXT_LEFT_OFFSET, BORDER_TOP_OFFSET);
}

- (void)selectWithFrame:(NSRect)aRect inView:(NSView *)controlView editor:(NSText *)textObj delegate:(id)anObject start:(NSInteger)selStart length:(NSInteger)selLength {
	[super selectWithFrame:[self textAreaForBounds:aRect] inView:controlView editor:textObj delegate:anObject start:selStart length:selLength];
}

- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
	NSTextView *textView = (NSTextView*)[super setUpFieldEditorAttributes:textObj];
	[textView setDrawsBackground:NO];

	return textView;
}

- (void)endEditing:(NSText *)textObj {
	//fix up any changes we might have made to the field editor in setUpFieldEditorAttributes:
//	[(NSTextView*)textObj setTextContainerInset:NSMakeSize(0, 0)];
	[super endEditing:textObj];
}

- (NSRect)clearButtonRectForBounds:(NSRect)rect {
	NSRect part, clear;
	
	NSDivideRect(rect, &clear, &part, CLEAR_BUTTON_IMG_DIM + BORDER_LEFT_OFFSET + 4.0, NSMaxXEdge);
	clear.origin.y -= 1.0;
	return clear;
}

- (NSRect)snapbackButtonRectForBounds:(NSRect)rect {
	return NSMakeRect(BORDER_LEFT_OFFSET, BORDER_TOP_OFFSET, MAX_STATE_IMG_DIM, MAX_STATE_IMG_DIM);	
}

- (NSRect)textAreaForBounds:(NSRect)rect {
	
	NSRect textRect = rect;
	textRect.origin.y += BORDER_TOP_OFFSET;
	textRect.origin.x += TEXT_LEFT_OFFSET;
	textRect.size.height = MAX_STATE_IMG_DIM;
	textRect.size.width = rect.size.width - 23;	
	//if ([self clearButtonIsVisible]) {
		textRect.size.width -= CLEAR_BUTTON_IMG_DIM - 1.0;
	//}
	
	return textRect;
}

- (BOOL)clearButtonIsVisible {
	return BUTTON_HIDDEN != clearButtonState;
}

- (void)setShowsClearButton:(BOOL)shouldShow {
	if ((BUTTON_HIDDEN != clearButtonState) != shouldShow) {
		NSView *controlView = [self controlView];
		clearButtonState = shouldShow ? BUTTON_NORMAL : BUTTON_HIDDEN;
		[controlView setNeedsDisplayInRect:[self clearButtonRectForBounds:[controlView bounds]]];
		[[controlView window] invalidateCursorRectsForView:controlView];
	}
}

- (BOOL)snapbackButtonIsVisible {
	return BUTTON_HIDDEN != snapbackButtonState;
}

- (void)setShowsSnapbackButton:(BOOL)shouldShow {
	NSView *controlView = [self controlView];
	//used for being notified from a mouseover-ing
	if ((snapbackButtonState != BUTTON_HIDDEN) != shouldShow) {
		snapbackButtonState = shouldShow ? BUTTON_NORMAL : BUTTON_HIDDEN;
		[controlView setNeedsDisplayInRect:[self snapbackButtonRectForBounds:[controlView bounds]]];
		[[controlView window] invalidateCursorRectsForView:controlView];
	}
	
}

- (BOOL)handleMouseDown:(NSEvent *)theEvent {
	DualField *controlView = (DualField *)[self controlView];
	
	if (![self clearButtonIsVisible] && ![self snapbackButtonIsVisible]) {
		return NO;
	}
	
	do {
		NSPoint mouseLoc = [controlView convertPoint:[theEvent locationInWindow] fromView:nil];
		
		if ([self clearButtonIsVisible])
			clearButtonState = [controlView mouse:mouseLoc inRect:[self clearButtonRectForBounds:[controlView bounds]]] ? BUTTON_PRESSED : BUTTON_NORMAL;
		
		if ([self snapbackButtonIsVisible])
			snapbackButtonState = [controlView mouse:mouseLoc inRect:[self snapbackButtonRectForBounds:[controlView bounds]]]  ? BUTTON_PRESSED : BUTTON_NORMAL;
		
		[controlView setNeedsDisplay:YES];
		
		NSEventType type = [theEvent type];
		if (type == NSLeftMouseUp || type == NSRightMouseUp) {
			if (BUTTON_PRESSED == snapbackButtonState) {
				[controlView snapback:nil];
			} else if (BUTTON_PRESSED == clearButtonState) {
				[NSApp tryToPerform:@selector(cancelOperation:) with:nil];
			}
			break;
		}
		theEvent = [[controlView window] nextEventMatchingMask: NSLeftMouseUpMask | NSLeftMouseDraggedMask | NSRightMouseUpMask | NSRightMouseDraggedMask];
	} while (1);
	
	return YES;
}
		
- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
	
	[super drawWithFrame:cellFrame inView:controlView];
	
	if (BUTTON_HIDDEN != clearButtonState) {
		NSImage *clearImg = [NSImage imageNamed:(clearButtonState == BUTTON_NORMAL ? @"Clear" : @"ClearPressed") ];
		[clearImg drawCenteredInRect:[self clearButtonRectForBounds:cellFrame]];
	}
	if (BUTTON_HIDDEN != snapbackButtonState) {
		NSRect snRect = [self snapbackButtonRectForBounds:cellFrame];
		NSEraseRect(centeredRectInRect(snRect, NSMakeSize(MAX_STATE_IMG_DIM, MAX_STATE_IMG_DIM)));
		NSImage *snapImg = [NSImage imageNamed:
							[(DualField *)controlView hasFollowedLinks] ? (snapbackButtonState == BUTTON_NORMAL ? @"LinkBack" : @"LinkBackPressed") :
							(snapbackButtonState == BUTTON_NORMAL ? @"SnapBack" : @"SnapBackPressed") ];
		[snapImg drawCenteredInRect:snRect];
	}
}


+ (BOOL)prefersTrackingUntilMouseUp {
	// NSCell returns NO for this by default. If you want to have trackMouse:inRect:ofView:untilMouseUp: always track until the mouse is up, then you MUST return YES. Otherwise, strange things will happen.
	return YES;
}


@end

@implementation DualField

+ (Class)cellClass {
	return [DualFieldCell class];
}

- (void)awakeFromNib {
	
	NSCell *dualFieldCell = [[[DualFieldCell alloc] init] autorelease];
	[dualFieldCell setAction:[[self cell] action]];
	[dualFieldCell setTarget:[[self cell] target]];
	[self setCell:dualFieldCell];
	//[self setDrawsBackground:NO];
	DualFieldCell *myCell = [self cell];
	//[myCell setWraps:YES];
	
	[self setDrawsBackground:NO];
	[self setBordered:NO];
	[self setBezeled:NO];
	[self setFocusRingType:NSFocusRingTypeExterior];
			
	[myCell setAllowsUndo:NO];
	[myCell setLineBreakMode:NSLineBreakByCharWrapping];
	
	//remember this now to make sure we always use the same one, in case +IBeamCursor just happens to return a different object later (hint hint)
	IBeamCursor = [[NSCursor IBeamCursor] retain];
	
	followedLinks = [[NSMutableArray alloc] init];
}

- (void)setTrackingRect {
	if (!docIconRectTag)
		docIconRectTag = [self addTrackingRect:[[self cell] snapbackButtonRectForBounds:[self bounds]] 
										 owner:self userData:NULL assumeInside:NO];	
}

- (void)dealloc {
	[snapbackString release];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[followedLinks release];
	
	[super dealloc];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)userData {
	unichar ch = 0x2318;
	
	if (tag == docIconTag) {
		//should be conditional on whether snapback exists, and include the snapback string
		if ([[self cell] snapbackButtonIsVisible]) {
			return [NSString stringWithFormat:NSLocalizedString(@"Go back to search; press %@-D to deselect", @"tooltip string for search/title field"), 
					[NSString stringWithCharacters:&ch length:1]];
		} else {
			return NSLocalizedString(@"Now searching for this text", @"tooltip string for search/title field");
		}
	} else if (tag == clearButtonTag) {
		if ([[self cell] clearButtonIsVisible]) {
			return NSLocalizedString(@"Clear the search; press ESC", @"tooltip string for search/title field");
		} else {
			return NSLocalizedString(@"Type any text to search; press Return to create a note", @"tooltip string for search/title field");
		}
	} else if (tag == textAreaTag) {
		if ([self showsDocumentIcon]) {
			return [NSString stringWithFormat:NSLocalizedString(@"Now editing this note; rename it with %@-R", @"tooltip string for search/title field"),
					[NSString stringWithCharacters:&ch length:1]];
		} else {
			return NSLocalizedString(@"Type any text to search; press Return to create a note", @"tooltip string for search/title field");
		}
	}
	return nil;
}

- (void)mouseEntered:(NSEvent *)theEvent {
	if ([theEvent trackingNumber] == docIconRectTag) {
		[[self cell] setShowsSnapbackButton:[self showsDocumentIcon]];
	} else {
		NSLog(@"got mouse entered on a different tracking number: %d", [theEvent trackingNumber]);
	}
}
- (void)mouseExited:(NSEvent *)theEvent {
	if ([theEvent trackingNumber] == docIconRectTag) {
		[[self cell] setShowsSnapbackButton:NO];
	}
}

- (void)resetCursorRects {
	NSRect bounds = [self bounds];
	
	NSRect textArea = [[self cell] textAreaForBounds:bounds];
	NSRect clearButtonArea = [[self cell] clearButtonRectForBounds:bounds];
	NSRect snapbackButtonArea = [[self cell] snapbackButtonRectForBounds:bounds];
	
	//always show the pointer over the doc icon area; there is always a doc icon of some sort, even if non-functional
	[self addCursorRect: snapbackButtonArea cursor: [NSCursor arrowCursor]];
	
	//conditionally show the pointer over the clear button area
	if ([[self cell] clearButtonIsVisible]) {
		[self addCursorRect: clearButtonArea cursor: [NSCursor arrowCursor]];
	} else {
		textArea = NSUnionRect(textArea, clearButtonArea);
	}
	[self addCursorRect: textArea cursor: IBeamCursor];
	
	[self removeAllToolTips];
	textAreaTag = [self addToolTipRect:textArea owner:self userData:NULL];
	clearButtonTag = [self addToolTipRect:clearButtonArea owner:self userData:NULL];	
	docIconTag = [self addToolTipRect:snapbackButtonArea owner:self userData:NULL];
}


- (void)reflectScrolledClipView:(NSClipView *)aClipView {	
	[super setKeyboardFocusRingNeedsDisplayInRect: [self bounds]];
}

- (void)mouseDown:(NSEvent*)anEvent {
    [[NSApp delegate] setIsEditing:NO];
	
	if ([[self cell] handleMouseDown:anEvent])
		return;
	
	[super mouseDown:anEvent];
    
}

- (BOOL)hasFollowedLinks {
	return [followedLinks count] != 0;
}
- (void)pushFollowedLink:(NoteBookmark*)aBM {

	[followedLinks addObject:aBM];
}

- (NoteBookmark*)popLastFollowedLink {
	
	NoteBookmark *aBookmark = [[followedLinks lastObject] retain];
	[followedLinks removeLastObject];
	 
	[[NSApp delegate] searchForString:[aBookmark searchString]];
	[[NSApp delegate] revealNote:[aBookmark noteObject] options:0];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearFollowedLinks) object:nil];

	return [aBookmark autorelease];
}

- (void)clearFollowedLinks {
	[followedLinks removeAllObjects];
}

- (void)setSnapbackString:(NSString*)string {
	
	NSString *proposedString = string ? [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
	
	if (proposedString != snapbackString /*the nil == nil case*/ && ![proposedString isEqualToString:snapbackString]) {
		[snapbackString release];
		snapbackString = [proposedString copy];		
	}
	if (![proposedString length]) {
		[[self cell] setShowsSnapbackButton:NO];
	}
	[self performSelector:@selector(clearFollowedLinks) withObject:nil afterDelay:0];
}
- (NSString*)snapbackString {
	return snapbackString;
}

/*- (BOOL)becomeFirstResponder {
	[[NSApp delegate] updateEmptyViewStatus];
	return [super becomeFirstResponder];
}*/

- (void)setShowsDocumentIcon:(BOOL)showsIcon {
	if (showsIcon != showsDocumentIcon) {
		showsDocumentIcon = showsIcon;
		[self setNeedsDisplay:YES];
	}
}

- (BOOL)showsDocumentIcon {
	return showsDocumentIcon;
}

- (BOOL)textView:(NSTextView *)aTextView shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString {
	
	//if ([replacementString rangeOfString:@"\n" options:NSLiteralSearch].location != NSNotFound) {
//		//NO! you cannot paste line feeds.
//		return NO;
//	}
	
	lastLengthReplaced = [replacementString length];
	
	return YES;
}

- (unsigned int)lastLengthReplaced {
	return lastLengthReplaced;
}

- (void)snapback:(id)sender {
	if ([self hasFollowedLinks]) {
		[self popLastFollowedLink];
	} else {
		[notesTable deselectAll:sender];
	}
}

+ (NSImage*)snapbackImageWithString:(NSString*)string {
	//get width of string, center rect around it,
	//lock focus, draw rounded rect, draw text, unlock focus
	
	static NSDictionary *smallTextAttrs = nil;
	static NSMutableDictionary *smallTextBackAttrs = nil;
	if (!smallTextAttrs) {
		smallTextAttrs = [[NSDictionary dictionaryWithObjectsAndKeys:
						   [NSFont systemFontOfSize:[NSFont smallSystemFontSize]], NSFontAttributeName, 
						   [NSColor whiteColor], NSForegroundColorAttributeName, nil] retain];
		[(smallTextBackAttrs = [smallTextAttrs mutableCopy]) setObject:[NSColor colorWithCalibratedWhite:0.44 alpha:1.0] forKey:NSForegroundColorAttributeName];
	}
	
	if ([string length] > 15) string = [[string substringToIndex:15] stringByAppendingString:NSLocalizedString(@"...", @"ellipsis character")];
	NSSize stringSize = [string sizeWithAttributes:smallTextAttrs];
	
	NSPoint textOffset = NSMakePoint(5.0f, 2.0f);
	NSRect wordRect = NSMakeRect(0, 0, ceilf(stringSize.width + textOffset.x * 2.0f), stringSize.height + textOffset.y * 2.0f);
	
	NSImage *image = [[NSImage alloc] initWithSize:wordRect.size];
	[image lockFocus];
	
	NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundRectInRect:NSInsetRect(wordRect, 1.5, 1.5) radius:1.5f];
	
	static LinearDividerShader *snapbackShader = nil;
	if (!snapbackShader) {
		snapbackShader = [[LinearDividerShader alloc] initWithStartColor:[NSColor colorWithDeviceRed:0.8 green:0.386 blue:0.019 alpha:1.0] 
																endColor:[NSColor colorWithDeviceRed:1.0 green:0.486 blue:0.039 alpha:1.0]];
	}
	
	
	[[NSGraphicsContext currentContext] saveGraphicsState];
	[backgroundPath addClip];
	[snapbackShader drawDividerInRect:wordRect withDimpleRect:NSZeroRect blendVertically:YES];	
	[[NSGraphicsContext currentContext] restoreGraphicsState];
	
	[[NSColor colorWithDeviceRed:0.63 green:0.20 blue:0.0 alpha:1.0] set];
	[backgroundPath stroke];
	
	[string drawAtPoint:NSMakePoint(textOffset.x, textOffset.y+1) withAttributes:smallTextBackAttrs];
	[string drawAtPoint:textOffset withAttributes:smallTextAttrs];
	
	[image unlockFocus];
	return [image autorelease];
}

- (void)drawRect:(NSRect)rect {
//	[super drawRect:rect];
	
	NSWindow *window = [self window];
	BOOL isActiveWin = [window isMainWindow];
	
	[NSGraphicsContext saveGraphicsState];
	[[NSGraphicsContext currentContext] setShouldAntialias:NO];
	
	NSRect tBounds = [self bounds];
	
	[[NSColor whiteColor] set];
	NSRectFill(NSInsetRect(tBounds, 5, 1));
	
	NSImage *leftCap = [NSImage imageNamed: isActiveWin ? @"DFCapLeftRounded" : @"DFCapLeftRoundedInactive"];
	[leftCap setFlipped:YES];
	NSRect leftImageRect = NSMakeRect(0, 0, [leftCap size].width, [leftCap size].height);
	[leftCap drawInRect:leftImageRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
	
	NSImage *rightCap = [NSImage imageNamed: isActiveWin ? @"DFCapRight" : @"DFCapRightInactive"];
	[rightCap setFlipped:YES];
	NSRect rightImageRect = NSMakeRect(tBounds.size.width - [rightCap size].width, 0, [rightCap size].width, [rightCap size].height);
	[rightCap drawInRect:rightImageRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];

	[[NSColor colorWithDeviceWhite: isActiveWin ? 0.31f : 0.62f alpha:1.0f] set];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(tBounds.origin.x + [leftCap size].width, tBounds.origin.y + .5) 
							  toPoint:NSMakePoint(tBounds.size.width - [rightCap size].width, tBounds.origin.y + .5)];
	[[NSColor colorWithDeviceWhite: isActiveWin ? 0.882f : 0.886f alpha:1.0f] set];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(tBounds.origin.x + [leftCap size].width, tBounds.origin.y + 1.5) 
							  toPoint:NSMakePoint(tBounds.size.width - [rightCap size].width, tBounds.origin.y + 1.5)];
	
	
	[[NSColor colorWithDeviceWhite: isActiveWin ? 0.447f : 0.627f alpha:1.0f] set];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(tBounds.origin.x + [leftCap size].width, tBounds.origin.y + tBounds.size.height - 1.5) 
							  toPoint:NSMakePoint(tBounds.size.width - [rightCap size].width, tBounds.origin.y + tBounds.size.height - 1.5)];
	[[NSColor colorWithDeviceWhite: 1.0 alpha:0.39f] set];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(tBounds.origin.x + [leftCap size].width, tBounds.origin.y + tBounds.size.height ) 
							  toPoint:NSMakePoint(tBounds.size.width - [rightCap size].width, tBounds.origin.y + tBounds.size.height )];
	
	NSImage *docIcon = [NSImage imageNamed: showsDocumentIcon ? @"Pencil" : @"Search" ];
	[docIcon setFlipped:YES];
	NSRect docImageRect = NSMakeRect(BORDER_LEFT_OFFSET, BORDER_TOP_OFFSET, [docIcon size].width, [docIcon size].height);
	[docIcon drawInRect:docImageRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
	
	[NSGraphicsContext restoreGraphicsState];
	
	//drawWithFrame: would make sense to override, but this works, too
	[[self cell] drawWithFrame:NSMakeRect(0, 0, NSWidth(tBounds), NSHeight(tBounds)) inView:self];
	
	if (IsLeopardOrLater) {
		//ALERT: TEMPORARY WORK-AROUND FOR TIGER FOCUS RING BUILDUP: DO NOT DRAW FOCUS RING ON TIGER
		if ([self currentEditor] && isActiveWin) {
			//draw focus ring
			[NSGraphicsContext saveGraphicsState];
			NSSetFocusRingStyle(NSFocusRingOnly);
			NSRect focusRect = NSInsetRect(tBounds, 0.0f, 0.5f);
			focusRect.origin.y -= 0.5f;
			//drawing could be sped up by a measurable amount if this were cached in a (partially transparent) image
			[[NSBezierPath bezierPathWithRoundRectInRect:focusRect radius:1.0f] fill];
			[NSGraphicsContext restoreGraphicsState];
		}
	}	
	
	
}

//elasticwork


- (void)flagsChanged:(NSEvent *)theEvent{
	[[NSApp delegate] flagsChanged:theEvent];
}

@end
