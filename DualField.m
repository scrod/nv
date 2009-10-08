#import "DualField.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "AppController.h"

@implementation DualFieldCell

- (id) init {
	self = [super init];
	if (self != nil) {
		[self setStringValue:@""];
		[self setEditable:YES];
		[self setSelectable:YES];
		[self setBezeled:YES];
		[self setWraps:YES];
		
	}
	return self;
}


- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
	NSTextView *textView = (NSTextView*)[super setUpFieldEditorAttributes:textObj];
	[textView setDrawsBackground:NO];
	
	return textView;
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
	NSCell *myCell = [self cell];
	//[myCell setWraps:YES];
		
	snapbackButton = [[NSButton alloc] initWithFrame:NSZeroRect];
	[snapbackButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
	[snapbackButton setBordered:NO];
	[snapbackButton setImagePosition:NSImageOnly];
	[snapbackButton setTarget:notesTable];
	[snapbackButton setAction:@selector(deselectAll:)];
	unichar ch = 0x2318;
	[snapbackButton setToolTip:[NSString stringWithFormat:NSLocalizedString(@"Continue searching (%@-D)", nil), 
		[NSString stringWithCharacters:&ch length:1]]];
	//[snapbackButton setMenu:[self snapbackMenu]];
	
	//[self _addSnapbackButtonForField];
		
	if (RunningTigerAppKitOrHigher) { // on 10.4
		[myCell setAllowsUndo:NO];
		[myCell setLineBreakMode:NSLineBreakByCharWrapping];
	}
	//use setParagraphStyle on 10.3?
}

- (void) resetCursorRects {
	
    [super resetCursorRects];
	
	if ([snapbackString length]) {
		NSRect rect = [self convertRect:[snapbackButton frame] fromView:nil];
		[self addCursorRect: rect cursor: [NSCursor arrowCursor]];
	}
	
} // resetCursorRects

//fix these to use more view-depending height positioning
- (void)_addSnapbackButtonForField {
	[snapbackButton retain];
	[snapbackButton removeFromSuperviewWithoutNeedingDisplay];
	[self addSubview:snapbackButton positioned:NSWindowAbove relativeTo:nil];
	NSRect colFrame = [self frame];
	NSSize buttonSize = [snapbackButton frame].size;
	[snapbackButton setFrame:NSMakeRect(colFrame.size.width - ([[snapbackButton image] size].width + 6),
										colFrame.size.height - 19, buttonSize.width, buttonSize.height)];
	[snapbackButton release];
	
	[[self window] invalidateCursorRectsForView:self];
}

- (void)_addSnapbackButtonForEditor:(NSText*)editor {
	//do we need to set the size anywhere else?
	NSSize tvSize = [self frame].size;
	//NSLog(@"tv width: %g, tf width: %g", [(NSTextView*)editor frame].size.width, tvSize.width);
	tvSize.width -= [snapbackButton frame].size.width + 6.0f;
	[(NSTextView*)editor setFrameSize:tvSize];
	
	//we also have to figure out how to tell when textView wraps to next "line", and redraw button
	
	[snapbackButton retain];
	[snapbackButton removeFromSuperviewWithoutNeedingDisplay];
	[[self superview] addSubview:snapbackButton positioned:NSWindowAbove relativeTo:nil];
	NSRect colFrame = [[self superview] frame];
	NSSize buttonSize = [snapbackButton frame].size;
	[snapbackButton setFrame:NSMakeRect(colFrame.size.width - ([[snapbackButton image] size].width + 14),
										colFrame.size.height - 30, buttonSize.width, buttonSize.height)];
	[snapbackButton release];
	
	[[self window] invalidateCursorRectsForView:self];
}

- (void)reflectScrolledClipView:(NSClipView *)aClipView {
	NSText *editor = [self currentEditor];
	if (editor)	[self updateButtonIfNecessaryForEditor:editor];
}

- (void)selectText:(id)sender {
	[super selectText:sender];
	
	NSText* editor = [self currentEditor];
	[(NSTextView*)editor setAllowsUndo:NO]; //for 10.3

	//[(NSTextView*)editor setDrawsBackground:NO];
	
	if ([snapbackString length]) {
		
		//move the button to this view?
		[self _addSnapbackButtonForEditor:editor];
		
		[(NSTextView*)editor setDrawsBackground:NO];		
	}
}

- (void)textDidEndEditing:(NSNotification *)aNotification {
	
	[super textDidEndEditing:aNotification];
	if ([snapbackString length]) {
		[self _addSnapbackButtonForField];
	}
	
}

- (void)setSnapbackString:(NSString*)string {
	
	NSString *proposedString = string ? [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
	
	if (proposedString != snapbackString /*the nil == nil case*/ && ![proposedString isEqualToString:snapbackString]) {
		[snapbackString release];
		snapbackString = [proposedString copy];
		
		if ([proposedString length] > 0) {
			NSImage *snapImage = [[self class] snapbackImageWithString:snapbackString];
			[snapbackButton setImage:snapImage];
			[snapbackButton setFrameSize:NSMakeSize([snapImage size].width + 2, 17)];
			
			if ([self currentEditor]) {
				[self _addSnapbackButtonForEditor:[self currentEditor]];
			} else {
				[self _addSnapbackButtonForField];
			}
		} else {
			[snapbackButton removeFromSuperview];
			NSTextView *editor = nil;
			if ((editor = (NSTextView *)[self currentEditor])) {
				//expand editor into empty button space
				NSSize tvSize = [self frame].size;
				//editor width always seems to be 4 px less than textfield width
				tvSize.width -= 4.0f;
				[editor setFrameSize:tvSize];
			}
			[[self window] invalidateCursorRectsForView:self];
		}
	} else {
		//we may already have the button set up, but it could still be wiped-out in some circumstances
		//(such as the text editor
		NSText *editor = [self currentEditor];
		if (editor)	[self updateButtonIfNecessaryForEditor:editor];
	}
}

/*- (BOOL)becomeFirstResponder {
	[[NSApp delegate] updateEmptyViewStatus];
	return [super becomeFirstResponder];
}*/

- (void)updateButtonIfNecessaryForEditor:(NSText*)editor {
	if ([snapbackString length] > 0 && [editor bounds].size.height > 17) {
		[snapbackButton setNeedsDisplay:YES];
	}
}

- (BOOL)textView:(NSTextView *)aTextView shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString {

	lastLengthReplaced = [replacementString length];

	return YES;
}

- (unsigned int)lastLengthReplaced {
	return lastLengthReplaced;
}

/*
- (BOOL)performKeyEquivalent:(NSEvent *)anEvent {
	unichar keyChar = [anEvent firstCharacterIgnoringModifiers];
	
	if (keyChar == NSCarriageReturnCharacter || keyChar == NSNewlineCharacter || keyChar == NSEnterCharacter) {
		
		if ([anEvent modifierFlags] & NSCommandKeyMask) {
			[notesTable deselectAll:self];
			[[self target] performSelector:[self action]];
			return YES;
		}
	}
	
	return [super performKeyEquivalent:anEvent];	
}*/

+ (NSBezierPath*)bezierPathWithRoundRectInRect:(NSRect)aRect radius:(float)radius  {
	NSBezierPath* path = [NSBezierPath bezierPath];
	float smallestEdge = MIN(NSWidth(aRect), NSHeight(aRect));
	radius = MIN(radius, 0.5f * smallestEdge);
	NSRect rect = NSInsetRect(aRect, radius, radius);
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMinX(rect), NSMinY(rect)) radius:radius startAngle:180.0 endAngle:270.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(rect), NSMinY(rect)) radius:radius startAngle:270.0 endAngle:360.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(rect), NSMaxY(rect)) radius:radius startAngle:  0.0 endAngle: 90.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMinX(rect), NSMaxY(rect)) radius:radius startAngle: 90.0 endAngle:180.0];
	[path closePath];
	return path;
}

+ (NSImage*)snapbackImageWithString:(NSString*)string {
	//get width of string, center rect around it,
	//lock focus, draw rounded rect, draw text, unlock focus
	
	static NSDictionary *smallTextAttrs = nil;
	static NSMutableDictionary *smallTextBackAttrs = nil;
	if (!smallTextAttrs || !smallTextBackAttrs) {
		smallTextAttrs = [[NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]], NSFontAttributeName, nil] retain];
		[(smallTextBackAttrs = [smallTextAttrs mutableCopy]) setObject:[NSColor whiteColor] forKey:NSForegroundColorAttributeName];
	}
	
	if ([string length] > 25) string = [[string substringToIndex:25] stringByAppendingString:NSLocalizedString(@"...", @"ellipsis character")];
	NSSize stringSize = [string sizeWithAttributes:smallTextAttrs];
	
	float arrowOffset = 8.0f;
	NSPoint textOffset = NSMakePoint(4.0f, 0.0f);
	NSRect wordRect = NSMakeRect(0, 0, ceilf(stringSize.width + textOffset.x * 2.0f + arrowOffset) + 2, stringSize.height + textOffset.y * 2.0f + 3);
	textOffset.x += arrowOffset + 1.0f;
	textOffset.y += 1.0f;
	
	NSImage *image = [[NSImage alloc] initWithSize:wordRect.size];
	[image lockFocus];
	
	NSBezierPath *backgroundPath = [[self class] bezierPathWithRoundRectInRect:NSInsetRect(wordRect, 1.5, 1.5) radius:5.0f];
	
	[[NSColor colorWithCalibratedWhite:0.85f alpha:1.0f] setFill];
	[backgroundPath fill];
	
	[[NSImage imageNamed:@"leftarrow"] compositeToPoint:NSMakePoint(5.0f, 5.0f) operation:NSCompositeSourceAtop];
	
	[[NSColor colorWithCalibratedWhite:0.60f alpha:1.0f] set];
	[backgroundPath stroke];
	
	[[NSColor whiteColor] set];
	[string drawAtPoint:NSMakePoint(textOffset.x, textOffset.y-1) withAttributes:smallTextBackAttrs];
	[string drawAtPoint:textOffset withAttributes:smallTextAttrs];
	
	[image unlockFocus];
	return [image autorelease];
}

- (NSMenu*)snapbackMenu {
	//create new note with this title
	//add to saved searches
	//clear this search
	//what else?
	
	/*
	NSMenu *theMenu = [[[NSMenu alloc] initWithTitle:@"Snapback Menu"] autorelease];
    
		NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:[[theColumn headerCell] stringValue] 
															  action:@selector(setStatusForSortedColumn:) 
													   keyEquivalent:@""] autorelease];
		[theMenuItem setTarget:self];
		[theMenuItem setRepresentedObject:theColumn];
		[theMenuItem setState:[[theColumn identifier] isEqualToString:sortKey]];
		
		[theMenu addItem:theMenuItem];

	return theMenu;
	 */
	return nil;
}

#define WBSEARCHTEXTFIELD_CANCEL_OFFSET         44
#define WBSEARCHTEXTFIELD_WIDTH_OFFSET          33

#if 0
- (void)drawRect:(NSRect)rect {
	[super drawRect:rect];

	//NSRect tBounds = [self bounds];
	
//	[[self cell] drawWithFrame:NSMakeRect(0,4,NSWidth(tBounds)/2,NSHeight(tBounds)-6) inView:self];
	
	//float tOffset = (showCancelButtons == NO) ? WBSEARCHTEXTFIELD_WIDTH_OFFSET : WBSEARCHTEXTFIELD_CANCEL_OFFSET;
	//[[self cell] drawWithFrame:NSMakeRect(0, 0, NSWidth(tBounds)-tOffset, NSHeight(tBounds)) inView:self];
	
	//[[NSImage imageNamed:@"deselect_document"] compositeToPoint:NSMakePoint(NSWidth(tBounds)-20,NSHeight(tBounds)-2.5) operation:NSCompositeCopy];
}
#endif

@end
