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


#import "LinkingEditor.h"
#import "GlobalPrefs.h"
#import "AppController.h"
#import "NotesTableView.h"
#import "FocusRingScrollView.h"
#import "NSTextFinder.h"
#import "LinkingEditor_Indentation.h"
#import "NSCollection_utils.h"
#import "AttributedPlainText.h"
#import "BodyScroller.h"
#import "NSString_NV.h"
#import "NVPasswordGenerator.h"

#include <CoreServices/CoreServices.h>
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
#include <Carbon/Carbon.h>
#endif

#define PASSWORD_SUGGESTIONS 0

#ifdef notyet
static long (*GetGetScriptManagerVariablePointer())(short);
#endif

@implementation LinkingEditor

- (void)awakeFromNib {
	
    prefsController = [GlobalPrefs defaultPrefs];
	
    [self setContinuousSpellCheckingEnabled:[prefsController checkSpellingAsYouType]];
	if (IsSnowLeopardOrLater) {
		[self setAutomaticTextReplacementEnabled:[prefsController useTextReplacement]];
	}

    [prefsController registerWithTarget:self forChangesInSettings:
	 @selector(setCheckSpellingAsYouType:sender:),
	 @selector(setUseTextReplacement:sender:),
	 @selector(setNoteBodyFont:sender:),
	 @selector(setMakeURLsClickable:sender:),
	 @selector(setSearchTermHighlightColor:sender:), nil];	
	
	[self setTextContainerInset:NSMakeSize(3, 8)];
	[self setSmartInsertDeleteEnabled:NO];
	[self setUsesRuler:NO];
	[self setUsesFontPanel:NO];

#if DELAYED_LAYOUT
	rectForSuppressedUpdate = NSZeroRect;
	inhibitingUpdates = didSetFutureRange = didRenderFully = didInvalidateLayout = NO;
	//should go in outletawoke method
	[(BodyScroller*)[[self enclosingScrollView] verticalScroller] setContentViewDelegate:self];
#else
	didRenderFully = NO;
#endif
	[[self layoutManager] setDelegate:self];
	
	[self setLinkTextAttributes:[self preferredLinkAttributes]];
	
	NSMenu *theMenu = [[[NSMenu alloc] initWithTitle:@"NVFontMenu"] autorelease];

	NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Cut",@"cut menu item title") action:@selector(cut:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[theMenu addItem:theMenuItem];
	
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Copy",@"copy menu item title") action:@selector(copy:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[theMenu addItem:theMenuItem];
	
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Paste",@"paste menu item title") action:@selector(paste:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[theMenu addItem:theMenuItem];
	
	[theMenu addItem:[NSMenuItem separatorItem]];
	
	NSMenu *formatMenu = [[[NSMenu alloc] initWithTitle:NSLocalizedString(@"Format", nil)] autorelease];
	
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Plain Text Style",nil) 
											  action:@selector(defaultStyle:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[formatMenu addItem:theMenuItem];
	
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Bold",nil) action:@selector(bold:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[formatMenu addItem:theMenuItem];
	
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Italic",nil) action:@selector(italic:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[formatMenu addItem:theMenuItem];
	
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Underline",nil) action:@selector(underlineNV:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[formatMenu addItem:theMenuItem];
	
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Format",@"format submenu title") action:NULL keyEquivalent:@""] autorelease];
	[theMenu addItem:theMenuItem];
	[theMenu setSubmenu:formatMenu forItem:theMenuItem];
	
	
	[self setMenu:theMenu];
    
    // Insert Password menus
    static BOOL additionalEditItems = YES;
    
    if (additionalEditItems) {
        additionalEditItems = NO;
		
        NSMenu *editMenu = [[NSApp mainMenu] numberOfItems] > 2 ? [[[NSApp mainMenu] itemAtIndex:2] submenu] : nil;
		
		if (IsSnowLeopardOrLater) {
			theMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Use Automatic Text Replacement", "use-text-replacement command in the edit menu")
													 action:@selector(toggleAutomaticTextReplacement:) keyEquivalent:@""];
			[theMenuItem setTarget:self];
			[editMenu addItem:theMenuItem];
			[theMenuItem release];
		}
		
		[editMenu addItem:[NSMenuItem separatorItem]];
        
        #if PASSWORD_SUGGESTIONS
        theMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"New Password...", "new password command in the edit menu")
												 action:@selector(showGeneratedPasswords:) keyEquivalent:@"\\"];
        [theMenuItem setKeyEquivalentModifierMask:NSCommandKeyMask];
        [theMenuItem setTarget:nil]; // First Responder being the current Link Editor
        [editMenu addItem:theMenuItem];
        [theMenuItem release];
        #endif
        
        theMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Insert New Password", "insert new password command in the edit menu")
												 action:@selector(insertGeneratedPassword:) keyEquivalent:@"\\"];
        #if PASSWORD_SUGGESTIONS
        [theMenuItem setAlternate:YES];
        #endif
        [theMenuItem setKeyEquivalentModifierMask:NSCommandKeyMask|NSAlternateKeyMask];
        [theMenuItem setTarget:nil]; // First Responder being the current Link Editor
        [editMenu addItem:theMenuItem];
        [theMenuItem release];
    }
	
	
	outletObjectAwoke(self);
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
    
    if ([selectorString isEqualToString:SEL_STR(setCheckSpellingAsYouType:sender:)]) {
	
		[self setContinuousSpellCheckingEnabled:[prefsController checkSpellingAsYouType]];
		
	} else if ([selectorString isEqualToString:SEL_STR(setUseTextReplacement:sender:)]) {
		
		if (IsSnowLeopardOrLater) {
			[self setAutomaticTextReplacementEnabled:[prefsController useTextReplacement]];
		}
    } else if ([selectorString isEqualToString:SEL_STR(setNoteBodyFont:sender:)]) {

		[self setTypingAttributes:[prefsController noteBodyAttributes]];
		//[textView setFont:[prefsController noteBodyFont]];
	} else if ([selectorString isEqualToString:SEL_STR(setMakeURLsClickable:sender:)]) {
		[self setLinkTextAttributes:[self preferredLinkAttributes]];
	} else if ([selectorString isEqualToString:SEL_STR(setSearchTermHighlightColor:sender:)]) {
		NSString *typedString = [[NSApp delegate] typedString];
		if (typedString) [self highlightTermsTemporarilyReturningFirstRange:typedString];
	}
}

- (BOOL)becomeFirstResponder {
	[(FocusRingScrollView*)[self enclosingScrollView] setHasFocus:YES];
	[notesTableView setShouldUseSecondaryHighlightColor:YES];

	if ([[[self window] currentEvent] type] == NSKeyDown && [[[self window] currentEvent] firstCharacter] == '\t') {
		//"indicate" the current cursor/selection when moving focus to this field, but only if the user did not click here
		NSRange range = [self selectedRange];
		if (range.length) {
			range = NSMakeRange(MIN([[self string] length] - 1, range.location), range.length);
			[self performSelector:@selector(indicateRange:) withObject:[NSValue valueWithRange:range] afterDelay:0];
		}
	}
	
#if DELAYED_LAYOUT
	[self _setFutureSelectionRangeWithinIndex:[[self string] length]];
#endif
		
	return [super becomeFirstResponder];
}

- (void)indicateRange:(NSValue*)rangeValue {
	if (IsLeopardOrLater) {
		[self showFindIndicatorForRange:[rangeValue rangeValue]];
	}
}

- (BOOL)resignFirstResponder {
	[(FocusRingScrollView*)[self enclosingScrollView] setHasFocus:NO];
	[notesTableView setShouldUseSecondaryHighlightColor:NO];
	
	return [super resignFirstResponder];
}

- (void)changeColor:(id)sender {
	//NSLog(@"You do not change the color.");
	return;
}

- (NSDictionary*)preferredLinkAttributes {
	if (![prefsController URLsAreClickable])
		return [NSDictionary dictionary];
	
	return [NSDictionary dictionaryWithObjectsAndKeys:
		[NSCursor pointingHandCursor], NSCursorAttributeName,
		[NSNumber numberWithInt:NSUnderlineStyleSingle], NSUnderlineStyleAttributeName,
		[NSColor blueColor], NSForegroundColorAttributeName, nil];
}

/*
- (BOOL)acceptsFirstResponder {
	
    return ([[controlField stringValue] length] > 0);
}*/

- (void)toggleAutomaticTextReplacement:(id)sender {
	
	[super toggleAutomaticTextReplacement:sender];
	
	[prefsController setUseTextReplacement:[self isAutomaticTextReplacementEnabled] sender:self];
}

- (void)toggleContinuousSpellChecking:(id)sender {

	[super toggleContinuousSpellChecking:sender];
	
	[prefsController setCheckSpellingAsYouType:[self isContinuousSpellCheckingEnabled] sender:self];
}

- (BOOL)isContinuousSpellCheckingEnabled {
	//optimization so that we don't spell-check while scrolling through notes that don't have focus
    NSView *responder = (NSView*)[[self window] firstResponder];
    
    return (responder == self && [super isContinuousSpellCheckingEnabled]);
}

#if DELAYED_LAYOUT

- (void)progressTowardFutureRange:(id)sender {
	unsigned int farthestLoc = [[self layoutManager] firstUnlaidCharacterIndex];
	
	//highlight all words from lastHighlightedIndex to farthestLoc, setting futureRange to range of first occurring found word
	[self _updateHighlightedRangesToIndex:farthestLoc];
	
	if (futureRange.location <= farthestLoc) {
		
		[self _setFutureSelectionRangeWithinIndex:farthestLoc];
	}
}

- (void)beginInhibitingUpdates {
	inhibitingUpdates = YES;
	
	rectForSuppressedUpdate = NSZeroRect;
	if (!didRenderFully) {
		rectForSuppressedUpdate = NSUnionRect(rectForSuppressedUpdate, [self visibleRect]);
		NSLog(@"probably dirty, so updating everything");
	}
}

- (void)setFutureSelectionRange:(NSRange)aRange highlightingWords:(NSString*)words {
	futureRange = aRange;
	didSetFutureRange = didInvalidateLayout = NO;
	lastHighlightedIndex = 0;
	
	[futureWordsToHighlight release];
	futureWordsToHighlight = [words retain];
	
	//rectForSuppressedUpdate = NSZeroRect;
	[(BodyScroller*)[[self enclosingScrollView] verticalScroller] clearSuppressedRects];
	
	//if we have focus, just force-scroll?
	if ([[self window] firstResponder] == self) {
		[self _setFutureSelectionRangeWithinIndex:[[self string] length]];
	} else if (!timer && [[self string] length] > 10*1024) {
		timer = [NSTimer scheduledTimerWithTimeInterval:0.08 target:self selector:@selector(progressTowardFutureRange:) userInfo:nil repeats:YES];
	}
	//need to draw loading status here somehow
}

- (void)_updateHighlightedRangesToIndex:(unsigned)loc {
	//unsigned loc = [[self string] length];
	
	NSString *bodyString = [self string];
	NSRange scanRange = NSMakeRange(lastHighlightedIndex, loc - lastHighlightedIndex);
	if (lastHighlightedIndex < loc && [futureWordsToHighlight length] && NSMaxRange(scanRange) <= [bodyString length]) {
		//find the range with the lowest location
		
		//NSLog(@"highlighting from %d to %d", lastHighlightedIndex, loc);
		CFArrayRef ranges = [bodyString copyRangesOfWordsInString:futureWordsToHighlight inRange:scanRange];
		if (ranges) {
			
			if (!futureRange.length) {
				CFRange earliestRange = CFRangeMake(NSNotFound, 0);
				CFIndex rangeIndex;
				for (rangeIndex = 0; rangeIndex < CFArrayGetCount(ranges); rangeIndex++) {
					CFRange *range = (CFRange *)CFArrayGetValueAtIndex(ranges, rangeIndex);
					if (range && range->length > 0 && range->location + range->length <= loc) {
						if (range->location < earliestRange.location)
							earliestRange = *range;
					}
				}
				
				if (earliestRange.location != NSNotFound) {
					futureRange.location = earliestRange.location;
					futureRange.length = earliestRange.length;
					//NSLog(@"set futureRange to found: %@", NSStringFromRange(futureRange));
				}
			}
			
			[self highlightRangesTemporarily:ranges];
			CFRelease(ranges);
		}
		lastHighlightedIndex = loc;
	} else {
		//NSLog(@"not scanning range %@ (max=%d)", NSStringFromRange(scanRange), NSMaxRange(scanRange));
	}
}

- (void)_setFutureSelectionRangeWithinIndex:(unsigned)loc {
	[timer invalidate];
	timer = nil;
	
	//[[[self enclosingScrollView] verticalScroller] setHidden:NO];
	[self _updateHighlightedRangesToIndex:loc];
	
	if (!didSetFutureRange) {
		//highlight words from lastHighlightedIndex to end of body
		
		if (futureRange.location != NSNotFound && NSMaxRange(futureRange) <= [[self string] length]) {
			didSetFutureRange = YES;
			[self setAutomaticallySelectedRange:futureRange];
			[self scrollRangeToVisible:futureRange];
		}
		
		inhibitingUpdates = NO;
		
		[self setNeedsDisplayInRect:rectForSuppressedUpdate avoidAdditionalLayout:YES];
		[(BodyScroller*)[[self enclosingScrollView] verticalScroller] restoreSuppressedRects];
	}
	
	//[(BodyScroller*)[[self enclosingScrollView] verticalScroller] setDisableUpdating:NO];
}

- (void)layoutManager:(NSLayoutManager *)aLayoutManager didCompleteLayoutForTextContainer:(NSTextContainer *)aTextContainer atEnd:(BOOL)flag {
	//NSLog(@"completed layout at end: %d", flag);
	
	didRenderFully = YES;
	if (!didInvalidateLayout) {
		//ideally we want to be able to do this as soon as firstUnlaidCharacterIndex is >= NSMaxRange(futureRange), but how to check other than polling?
		[self _setFutureSelectionRangeWithinIndex:[[self string] length]];
		//[self setNeedsDisplayInRect:[self visibleRect] avoidAdditionalLayout:YES];
	}
	
}
- (void)layoutManagerDidInvalidateLayout:(NSLayoutManager *)aLayoutManager {
	//NSLog(@"invalidated layout");
	didInvalidateLayout = YES;
	didRenderFully = NO;	
}

- (BOOL)readyToDraw {
	//return didRenderFully || didInvalidateLayout || didSetFutureRange;
	return !inhibitingUpdates;
}

- (void)setNeedsDisplayInRect:(NSRect)aRect avoidAdditionalLayout:(BOOL)flag {
	if (![self readyToDraw]) {
		rectForSuppressedUpdate = NSUnionRect(rectForSuppressedUpdate, aRect);
	} else {
		[super setNeedsDisplayInRect:aRect avoidAdditionalLayout:flag];
	}
}
#else

- (BOOL)didRenderFully {
	return didRenderFully;
}

- (void)layoutManager:(NSLayoutManager *)aLayoutManager didCompleteLayoutForTextContainer:(NSTextContainer *)aTextContainer atEnd:(BOOL)flag {
	didRenderFully = YES;
}
- (void)layoutManagerDidInvalidateLayout:(NSLayoutManager *)aLayoutManager {
	didRenderFully = NO;	
}
#endif

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard type:(NSString *)type {
	//NSLog(@"readSelectionFromPasteboard: %@ (total %@)", type, [[pboard types] description]);
	
	if ([type isEqualToString:NSFilenamesPboardType]) {
		//paste as a file:// URL, so that it can be linked
		NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
		if ([files isKindOfClass:[NSArray class]]) {
			NSMutableString *allURLsString = [NSMutableString string];
			unsigned int i;
			BOOL foundURL = NO;
			for (i=0; i<[files count]; i++) {
				NSURL *url = [NSURL fileURLWithPath:[files objectAtIndex:i]];
				if (url) {
					[allURLsString appendFormat:@"<%@>", 
						[[url absoluteString] stringByReplacingOccurrencesOfString:@"file://localhost" withString:@"file://"]];
					foundURL = YES;
				}
				if (i < [files count] - 1) [allURLsString appendString:@"\n"];
			}
			if (foundURL) {
				NSRange selectedRange = [self rangeForUserTextChange];
				if ([self shouldChangeTextInRange:selectedRange replacementString:allURLsString]) {
					[self replaceCharactersInRange:selectedRange withString:allURLsString];
					[self didChangeText];
					
					return YES;
				}
			}
		}
	}
	
	if ([type isEqualToString:NSRTFPboardType] || [type isEqualToString:NVPTFPboardType]) {
		//strip formatting if RTF and stick it into a new pboard
		NSMutableAttributedString *newString = [[[NSMutableAttributedString alloc] initWithRTF:[pboard dataForType:type] 
																				   documentAttributes:nil] autorelease];
		NSRange selectedRange = [self rangeForUserTextChange];
		if ([self shouldChangeTextInRange:selectedRange replacementString:[newString string]]) {
			
			if (![type isEqualToString:NVPTFPboardType]) {
				//remove the link attribute, because it will be re-added after we paste, and restyleText would preserve it otherwise
				//and we only want real URLs to be linked
				[newString removeAttribute:NSLinkAttributeName range:NSMakeRange(0, [newString length])];
				[newString restyleTextToFont:[prefsController noteBodyFont] usingBaseFont:nil];
			}
						
			[self replaceCharactersInRange:selectedRange withRTF:[newString RTFFromRange:
								   NSMakeRange(0, [newString length]) documentAttributes:nil]];

			//paragraph styles will ALWAYS be added _after_ replaceCharactersInRange, it seems
			//[[self textStorage] removeAttribute:NSParagraphStyleAttributeName range:NSMakeRange(0, [[self string] length])];
			[self didChangeText];
			
			return YES;
		}
	}
	
	return [super readSelectionFromPasteboard:pboard type:type];
}

- (NSArray *)acceptableDragTypes {
	
	return [self readablePasteboardTypes];
}

- (NSArray *)readablePasteboardTypes {
	NSMutableArray *types = [NSMutableArray arrayWithObjects:NSFilenamesPboardType, NVPTFPboardType, NSStringPboardType, nil];
	
	if ([prefsController pastePreservesStyle]) {
		[types insertObject:NSRTFPboardType atIndex:2];
	}
	
	return types;
}


- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard type:(NSString *)type {

	if ([type isEqualToString:NVPTFPboardType]) {
		//always preserve RTF to allow pasting into ourselves; prejudice against external sources
		[pboard setData:[self RTFFromRange:[self selectedRange]] forType:NVPTFPboardType];
		return YES;
	}
	
	return [super writeSelectionToPasteboard:pboard type:type];
}

#define COPY_PASTE_DEBUG 0

- (NSArray *)writablePasteboardTypes {
	NSMutableArray *types = [NSMutableArray arrayWithObjects:NVPTFPboardType, NSStringPboardType, nil];
	
	NSRange selectedRange = [self selectedRange];
	if (selectedRange.length) {
		
		NSRange firstAttributeRange;
		[[self textStorage] attributesAtIndex:selectedRange.location effectiveRange:&firstAttributeRange];
		if (firstAttributeRange.length < selectedRange.length) {
			//there are multiple styles across the selected text
			
			NSAttributedString *newString = [[self textStorage] attributedSubstringFromRange:selectedRange];
			NSRange effectiveRange = NSMakeRange(0,0);
			unsigned int stringLength = [newString length];
			
			//iterate over all styles; if any are acceptable, copy as RTF
			while (NSMaxRange(effectiveRange) < stringLength) {
				// Get the attributes for the current range
				NSDictionary *attributes = [newString attributesAtIndex:NSMaxRange(effectiveRange) effectiveRange:&effectiveRange];
				
				if ([attributes attributesHaveFontTrait:NSBoldFontMask orAttribute:NSStrokeWidthAttributeName])
					goto copyRTFType;
				if ([attributes attributesHaveFontTrait:NSItalicFontMask orAttribute:NSObliquenessAttributeName])
					goto copyRTFType;
				if ([attributes attributesHaveFontTrait:0 orAttribute:NSUnderlineStyleAttributeName])
					goto copyRTFType;
			}
#if COPY_PASTE_DEBUG
			NSLog(@"false alarm: no real styles");
#endif
			
		} else {
#if COPY_PASTE_DEBUG
			NSLog(@"homogeneous style");
#endif
		}
		
		if (0) {
copyRTFType:
			//we have more than a single styling segment within the selection--grudgingly allow regular RTF copying
#if COPY_PASTE_DEBUG
			NSLog(@"copying RTF due to multiple attributes");
			[[self layoutManager] addTemporaryAttributes:[prefsController searchTermHighlightAttributes] forCharacterRange:effectiveRange];
#endif
			[types insertObject:NSRTFPboardType atIndex:1];
		}
	}
	
	return types;
}

- (void)underlineNV:(id)sender {
	
	//we don't respond to the font panel, so underline it ourselves
		[self applyStyleOfTrait:0 alternateAttributeName:NSUnderlineStyleAttributeName 
	alternateAttributeValue:[NSNumber numberWithInt:NSUnderlineStyleSingle]];
	
	[[self undoManager] setActionName:NSLocalizedString(@"Underline",nil)];
}

#define STROKE_WIDTH_FOR_BOLD (-3.50)
#define OBLIQUENESS_FOR_ITALIC (0.20)
- (void)bold:(id)sender {	
	[self applyStyleOfTrait:NSBoldFontMask alternateAttributeName:NSStrokeWidthAttributeName 
	alternateAttributeValue:[NSNumber numberWithFloat:STROKE_WIDTH_FOR_BOLD]];	
	
	[[self undoManager] setActionName:NSLocalizedString(@"Bold",nil)];
}
- (void)italic:(id)sender {
	[self applyStyleOfTrait:NSItalicFontMask alternateAttributeName:NSObliquenessAttributeName 
	alternateAttributeValue:[NSNumber numberWithFloat:OBLIQUENESS_FOR_ITALIC]];	
	
	[[self undoManager] setActionName:NSLocalizedString(@"Italic",nil)];
}

- (void)applyStyleOfTrait:(NSFontTraitMask)trait alternateAttributeName:(NSString*)attrName alternateAttributeValue:(id)value {
	
	NSFont *font = nil;
	NSMutableDictionary *attributes = nil;
	BOOL hasTrait = NO;
	
	if ([self selectedRange].length) {
		NSRange limitRange, effectiveRange;
		NSTextStorage *text = [self textStorage];
		limitRange = [self selectedRange];
		
		if ([self shouldChangeTextInRange:limitRange replacementString:nil]) {
			
			NSDictionary *firstAttrs = [text attributesAtIndex:limitRange.location longestEffectiveRange:NULL inRange:limitRange];
			hasTrait = [firstAttrs attributesHaveFontTrait:trait orAttribute:attrName];
			
			[text beginEditing];
			while (limitRange.length > 0) {
				attributes = [[text attributesAtIndex:limitRange.location longestEffectiveRange:&effectiveRange 
											  inRange:limitRange] mutableCopyWithZone:nil];
				if (!attributes) attributes = [[prefsController noteBodyAttributes] mutableCopyWithZone:nil];
				font = [attributes objectForKey:NSFontAttributeName];
				
				[attributes applyStyleInverted:hasTrait trait:trait forFont:font alternateAttributeName:attrName alternateAttributeValue:value];
				[text setAttributes:attributes range:effectiveRange];
				[attributes release];
				
				limitRange = NSMakeRange( NSMaxRange( effectiveRange ), NSMaxRange( limitRange ) - NSMaxRange( effectiveRange ) );
			}
			[text endEditing];
			[self didChangeText];
		}
	} else {
		attributes = [[self typingAttributes] mutableCopyWithZone:nil];
		if (!attributes) attributes = [[prefsController noteBodyAttributes] mutableCopyWithZone:nil];
		font = [attributes objectForKey:NSFontAttributeName];
		
		hasTrait = [attributes attributesHaveFontTrait:trait orAttribute:attrName];
		[attributes applyStyleInverted:hasTrait trait:trait forFont:font alternateAttributeName:attrName alternateAttributeValue:value];
		[self setTypingAttributes:attributes];
		
		[attributes release];
	}
	
}

- (void)removeHighlightedTerms {
	[[self layoutManager] removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0, [[self string] length])];
}


//use with rangesOfWordsInString:(NSString*)findString earliestRange:(NSRange*)aRange inRange:
- (void)highlightRangesTemporarily:(CFArrayRef)ranges {
	CFIndex rangeIndex;
	int bodyLength = [[self string] length];
	NSDictionary *highlightDict = [prefsController searchTermHighlightAttributes];
	
	for (rangeIndex = 0; rangeIndex < CFArrayGetCount(ranges); rangeIndex++) {
		CFRange *range = (CFRange *)CFArrayGetValueAtIndex(ranges, rangeIndex);
		
		if (range && range->length > 0 && range->location + range->length <= bodyLength) {
			[[self layoutManager] addTemporaryAttributes:highlightDict forCharacterRange:*(NSRange*)range];
		} else {
			NSLog(@"highlightRangesTemporarily: Invalid range (%@)", range ? NSStringFromRange(*(NSRange*)range) : @"null");
		}
	}
}

- (NSRange)highlightTermsTemporarilyReturningFirstRange:(NSString*)typedString {
	
	//if lengths of respective UTF8-string equivalents for contentString are the same, we should revert to cstring-based algorithm
	
	CFStringRef quoteStr = CFSTR("\"");
	NSRange firstRange = NSMakeRange(NSNotFound,0);
	CFRange quoteRange = CFStringFind((CFStringRef)typedString, quoteStr, 0);
	CFArrayRef terms = CFStringCreateArrayBySeparatingStrings(NULL, (CFStringRef)typedString, 
															  quoteRange.location == kCFNotFound ? CFSTR(" ") : quoteStr);
	if (terms) {
		CFIndex termIndex, rangeIndex;
		CFStringRef bodyString = (CFStringRef)[self string];
		NSDictionary *highlightDict = [prefsController searchTermHighlightAttributes];
		
		for (termIndex = 0; termIndex < CFArrayGetCount(terms); termIndex++) {
			CFStringRef term = CFArrayGetValueAtIndex(terms, termIndex);
			if (CFStringGetLength(term) > 0) {
				CFArrayRef ranges = CFStringCreateArrayWithFindResults(NULL, bodyString, term, CFRangeMake(0, CFStringGetLength(bodyString)),
																	   kCFCompareCaseInsensitive);
				if (!ranges)
					continue;
				for (rangeIndex = 0; rangeIndex < CFArrayGetCount(ranges); rangeIndex++) {
					CFRange *range = (CFRange *)CFArrayGetValueAtIndex(ranges, rangeIndex);
					
					if (range && range->length > 0 && range->location + range->length <= CFStringGetLength(bodyString)) {
						if (firstRange.location > (NSUInteger)range->location) firstRange = *(NSRange*)range;
						[[self layoutManager] addTemporaryAttributes:highlightDict forCharacterRange:*(NSRange*)range];
					} else {
						NSLog(@"highlightTermsTemporarily: Invalid range (%@)", range ? NSStringFromRange(*(NSRange*)range) : @"?");
					}
				}
				CFRelease(ranges);
			}
		}
		CFRelease(terms);
	}
	return (firstRange);
}

- (NSRange)selectionRangeForProposedRange:(NSRange)proposedSelRange granularity:(NSSelectionGranularity)granularity {
	if (granularity != NSSelectByWord || [[self string] length] == proposedSelRange.location) {
		// If it's not a double-click return unchanged
		return [super selectionRangeForProposedRange:proposedSelRange granularity:granularity];
	}
	
	unsigned int location = [super selectionRangeForProposedRange:proposedSelRange granularity:NSSelectByCharacter].location;
	int originalLocation = location;
	
	NSString *completeString = [self string];
	unichar characterToCheck = [completeString characterAtIndex:location];
	unsigned short skipMatchingBrace = 0;
	unsigned int lengthOfString = [completeString length];
	if (lengthOfString == proposedSelRange.location) { // To avoid crash if a double-click occurs after any text
		return [super selectionRangeForProposedRange:proposedSelRange granularity:granularity];
	}
	
	BOOL triedToMatchBrace = NO;
	
	char *rightGroupings = ")}]>";
	char *leftGroupings = "({[<";
	int groupingIndex = 0;
	
	char *rightChar = strchr(rightGroupings, (char)characterToCheck);
	if (rightChar) {
		groupingIndex = rightChar - rightGroupings;
		
		triedToMatchBrace = YES;
		while (location--) {
			characterToCheck = [completeString characterAtIndex:location];
			if (characterToCheck == leftGroupings[groupingIndex]) {
				if (!skipMatchingBrace) {
					return NSMakeRange(location, originalLocation - location + 1);
				} else {
					skipMatchingBrace--;
				}
			} else if (characterToCheck == *rightChar) {
				skipMatchingBrace++;
			}
		}
		//NSBeep();
	}
	
	char *leftChar = strchr(leftGroupings, (char)characterToCheck);
	if (leftChar) {
		groupingIndex = leftChar - leftGroupings;
		
		triedToMatchBrace = YES;
		while (++location < lengthOfString) {
			characterToCheck = [completeString characterAtIndex:location];
			if (characterToCheck == rightGroupings[groupingIndex]) {
				if (!skipMatchingBrace) {
					return NSMakeRange(originalLocation, location - originalLocation + 1);
				} else {
					skipMatchingBrace--;
				}
			} else if (characterToCheck == *leftChar) {
				skipMatchingBrace++;
			}
		}
		//NSBeep();
	}
		
	// If it has a found a "starting" brace but not found a match, a double-click should only select the "starting" brace and not what it usually would select at a double-click
	if (triedToMatchBrace) {
		return [super selectionRangeForProposedRange:NSMakeRange(proposedSelRange.location, 1) granularity:NSSelectByCharacter];
	} else {
		return [super selectionRangeForProposedRange:proposedSelRange granularity:granularity];
	}
}

- (NSRange)selectedRangeWasAutomatic:(BOOL*)automatic {
	NSRange myRange = [self selectedRange];
	if (automatic) {
		*automatic = !didRenderFully || NSEqualRanges(lastAutomaticallySelectedRange, myRange);
	}
	return myRange;
}

- (void)setAutomaticallySelectedRange:(NSRange)newRange {
	lastAutomaticallySelectedRange = newRange;
	didChangeIntoAutomaticRange = NO;
	[self setSelectedRange:newRange];
}

- (IBAction)performFindPanelAction:(id)sender {
	id controller = [NSApp delegate];
    NSString *typedString = [controller typedString];
	NSString *currentFindString = nil;
    
    if (!typedString) typedString = [controlField stringValue];
	typedString = [typedString stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    
    NSTextFinder *textFinder = [NSTextFinder sharedTextFinder];
    if ([typedString length] > 0 && ![lastImportedFindString isEqualToString:typedString]) {
		
		NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:NSFindPboard];
		[pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
		[pasteboard setString:typedString forType:NSStringPboardType];
		
		if ([textFinder respondsToSelector:@selector(loadFindStringFromPasteboard)])
			[textFinder loadFindStringFromPasteboard];
		else
			NSLog(@"Apple changed NSTextFinder (loadFindStringFromPasteboard)");
		
		[lastImportedFindString release];
		lastImportedFindString = [typedString retain];
    }
	
	[currentFindString release];
	if ([textFinder respondsToSelector:@selector(findString)])
		currentFindString = [[textFinder findString] retain];
    else
		NSLog(@"Apple changed NSTextFinder (findString)");
    
    int rowNumber = -1;
    int totalNotes = [notesTableView numberOfRows];
    int tag = [sender tag];
    
    if (![controller selectedNoteObject]) {
		
		rowNumber = (tag == NSFindPanelActionPrevious ? totalNotes - 1 : 0);
		
    } else if (textFinder && [textFinder nv_lastFindWasSuccessful] == LAST_FIND_NO &&	//if the last find op. didn't work
			   selectedRangeDuringFind.location == [self selectedRange].location &&	//and user didn't change the selection
			   noteDuringFind == [controller selectedNoteObject] &&					//or select a different note
			   [stringDuringFind isEqualToString:currentFindString]) {				//or type a new search string
			   
		//then go to next/previous note in the list
		int selectedRow = [notesTableView selectedRow];
		rowNumber = (tag == NSFindPanelActionPrevious ? (selectedRow < 1 ? totalNotes - 1 : selectedRow - 1) : 
					 (selectedRow >= totalNotes - 1 ? 0 : selectedRow + 1));
    }
    
    if (rowNumber > -1 && tag != NSFindPanelActionShowFindPanel) {
		//when skipping notes, also set the selection depending on find direction
		[notesTableView selectRowAndScroll:rowNumber];
		[self setSelectedRange:NSMakeRange((tag == NSFindPanelActionPrevious ? [[self string] length] : 0),0)];
    }
    
	if ([controller selectedNoteObject])
		[[self window] makeFirstResponder:self];
	
    [super performFindPanelAction:sender];
	
	[stringDuringFind release];
	stringDuringFind = [currentFindString retain];
	noteDuringFind = [controller selectedNoteObject];
	selectedRangeDuringFind = [self selectedRange];
	lastAutomaticallySelectedRange = selectedRangeDuringFind;
}

- (BOOL)performKeyEquivalent:(NSEvent *)anEvent {
	
	unichar keyChar = [anEvent firstCharacterIgnoringModifiers];
	
	if (keyChar == NSCarriageReturnCharacter || keyChar == NSNewlineCharacter || keyChar == NSEnterCharacter) {
		
		if ([anEvent modifierFlags] & NSCommandKeyMask) {
			unsigned charIndex = [self selectedRange].location;
			
			id aLink = [self highlightLinkAtIndex:charIndex];
			if ([aLink isKindOfClass:[NSURL class]]) {
				[self clickedOnLink:aLink atIndex:charIndex];
				return YES;
			}
		}
	}
	
	return [super performKeyEquivalent:anEvent];
}

- (void)keyDown:(NSEvent*)anEvent {
	unichar keyChar = [anEvent firstCharacterIgnoringModifiers];

	if (keyChar == NSBackTabCharacter) {
		//apparently interpretKeyEvents: on 10.3 does not call insertBacktab
		//maybe it works on someone else's 10.3 Mac
		[self doCommandBySelector:@selector(insertBacktab:)];
		return;
	}
	[super keyDown:anEvent];
}

- (BOOL)jumpToRenaming {
	NSEvent *event = [[self window] currentEvent];
	if ([event type] == NSKeyDown && ![event isARepeat] && NSEqualRanges([self selectedRange], NSMakeRange(0, 0))) {
		//command-left at the beginning of the note--jump to editing the title!
		[[NSApp delegate] renameNote:nil];
		NSText *editor = [notesTableView currentEditor];
		NSRange endRange = NSMakeRange([[editor string] length], 0);
		[editor setSelectedRange:endRange];
		[editor scrollRangeToVisible:endRange];
		return YES;
	}
	return NO;
}

- (void)moveToLeftEndOfLine:(id)sender {
	if (![self jumpToRenaming]) 
		[super moveToLeftEndOfLine:sender];
}

- (void)moveToBeginningOfLine:(id)sender {
	if (![self jumpToRenaming]) 
		[super moveToBeginningOfLine:sender];
}

- (void)insertTab:(id)sender {
	//check prefs for tab behavior

	BOOL wasAutomatic = NO;
	[self selectedRangeWasAutomatic:&wasAutomatic];
	
	if ([prefsController tabKeyIndents] && (!wasAutomatic || ![[self string] length] || didChangeIntoAutomaticRange)) {
		[self insertTabIgnoringFieldEditor:sender];		
	} else {
		[[self window] selectNextKeyView:self];
	}
}

- (void)insertBacktab:(id)sender {
	[[self window] selectPreviousKeyView:self];
}

- (void)insertTabIgnoringFieldEditor:(id)sender {
	
	
	BOOL shouldShiftText = NO;
	
	if ([self selectedRange].length > 0) { // Check to see if the selection is in the text or if it's at the beginning of a line or in whitespace; if one doesn't do this one shifts the line if there's only one suggestion in the auto-complete
		NSRange rangeOfFirstLine = [[self string] lineRangeForRange:NSMakeRange([self selectedRange].location, 0)];
		unsigned int firstCharacterOfFirstLine = rangeOfFirstLine.location;
		while ([[self string] characterAtIndex:firstCharacterOfFirstLine] == ' ' || [[self string] characterAtIndex:firstCharacterOfFirstLine] == '\t') {
			firstCharacterOfFirstLine++;
		}
		if ([self selectedRange].location <= firstCharacterOfFirstLine) {
			shouldShiftText = YES;
		}
	}
	
	if (shouldShiftText) {
		[self shiftRightAction:nil];
	} else if ([prefsController softTabs]) {
		int numberOfSpacesPerTab = [prefsController numberOfSpacesInTab];

		int locationOnLine = [self selectedRange].location - [[self string] lineRangeForRange:[self selectedRange]].location;
		if (numberOfSpacesPerTab != 0) {
			int numberOfSpacesLess = locationOnLine % numberOfSpacesPerTab;
			numberOfSpacesPerTab = numberOfSpacesPerTab - numberOfSpacesLess;
		}
		NSMutableString *spacesString = [[NSMutableString alloc] initWithCapacity:numberOfSpacesPerTab];
		while (numberOfSpacesPerTab--) {
			[spacesString appendString:@" "];
		}
		
		[self insertText:spacesString];
		[spacesString release];
	} else {
		[self insertText:@"\t"];
	}
}

- (void)deleteBackward:(id)sender {
	
	NSRange charRange = [self rangeForUserTextChange];
	if (charRange.location != NSNotFound) {
		if (charRange.length > 0) {
			// Non-zero selection.  Delete normally.
			[super deleteBackward:sender];
		} else {
			if (charRange.location == 0) {
				// At beginning of text.  Delete normally.
				[super deleteBackward:sender];
			} else {
				NSString *string = [self string];
				NSRange paraRange = [string lineRangeForRange:NSMakeRange(charRange.location - 1, 1)];
				if (paraRange.location == charRange.location) {
					// At beginning of line.  Delete normally.
					[super deleteBackward:sender];
				} else {
					unsigned tabWidth = [prefsController numberOfSpacesInTab];
					unsigned indentWidth = 4;
					BOOL usesTabs = ![prefsController softTabs];
					NSRange leadingSpaceRange = paraRange;
					unsigned leadingSpaces = [string numberOfLeadingSpacesFromRange:&leadingSpaceRange tabWidth:tabWidth];
					
					if (charRange.location > NSMaxRange(leadingSpaceRange)) {
						// Not in leading whitespace.  Delete normally.
						[super deleteBackward:sender];
					} else {
						if ([string rangeOfString:@"\t" options:NSLiteralSearch range:leadingSpaceRange].location == NSNotFound) {
							//if this line was indented only with spaces, then keep the soft-tabbed-indentation
							usesTabs = NO;
						} else if ([string rangeOfString:@" " options:NSLiteralSearch range:leadingSpaceRange].location != NSNotFound && ![prefsController _bodyFontIsMonospace]) {
							//mixed tabs and spaces, and we have a proportional font -- what a mess! just revert to normal backward-deletes
							[super deleteBackward:sender];
							return;
						}
						
						NSTextStorage *text = [self textStorage];
						unsigned leadingIndents = leadingSpaces / indentWidth;
						NSString *replaceString;
						
						// If we were indented to an fractional level just go back to the last even multiple of indentWidth, if we were exactly on, go back a full level.
						if (leadingSpaces % indentWidth == 0) {
							leadingIndents--;
						}
						leadingSpaces = leadingIndents * indentWidth;
						
						replaceString = ((leadingSpaces > 0) ? [NSString tabbifiedStringWithNumberOfSpaces:leadingSpaces tabWidth:tabWidth usesTabs:usesTabs] : @"");
						if ([self shouldChangeTextInRange:leadingSpaceRange replacementString:replaceString]) {
							NSDictionary *newTypingAttributes;
							if (charRange.location < [string length]) {
								newTypingAttributes = [[text attributesAtIndex:charRange.location effectiveRange:NULL] retain];
							} else {
								newTypingAttributes = [[text attributesAtIndex:(charRange.location - 1) effectiveRange:NULL] retain];
							}
							
							[text replaceCharactersInRange:leadingSpaceRange withString:replaceString];
							
							[self setTypingAttributes:newTypingAttributes];
							[newTypingAttributes release];
							
							[self didChangeText];
						}
					}
				}
			}
		}
	}
}

//maybe if we knew we would always have a mono-spaced font
/*- (void)insertNewline:(id)sender {
	NSString *lineEnding = @"\n";
	NSRange charRange = [self rangeForUserTextChange];
	if (charRange.location != NSNotFound) {
		NSString *insertString = (lineEnding ? lineEnding : @"");
		NSString *string = [self string];
		if (charRange.location > 0) {
			if (!lineEnding) {
				// the newline has already been inserted.  Back up by one char.
				charRange.location--;
			}
			if ((charRange.location > 0) && !IsHardLineBreakUnichar([string characterAtIndex:(charRange.location - 1)], string, charRange.location - 1)) {
				unsigned tabWidth = [prefsController numberOfSpacesInTab];
				NSRange paraRange = [string lineRangeForRange:NSMakeRange(charRange.location - 1, 1)];
				unsigned leadingSpaces = [string numberOfLeadingSpacesFromRange:&paraRange tabWidth:tabWidth];

				insertString = [insertString stringByAppendingString:[NSString tabbifiedStringWithNumberOfSpaces:leadingSpaces tabWidth:tabWidth 
																										usesTabs:![prefsController softTabs]]];
			}
		}
		[self insertText:insertString];
	}	
}*/

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
	//need to fix this for better style detection
	
	SEL action = [menuItem action];
	if (action == @selector(defaultStyle:) ||
		action == @selector(bold:) ||
		action == @selector(italic:) ||
		action == @selector(underlineNV:)) {
		
		NSRange effectiveRange = NSMakeRange(0,0), range = [self selectedRange];
		NSDictionary *attrs = nil;
		BOOL multipleAttributes = NO;
		if (range.length) {
			//we have something selected--find the attributes of the first thing in the range
			attrs = [[self textStorage] attributesAtIndex:range.location effectiveRange:&effectiveRange];
			if (effectiveRange.length < range.length) {
				//it's a multiple attribute range piece--don't want to bother
				multipleAttributes = YES;
			}
			//NSLog(@"sel attrs: %@", attrs);
		} else {
			//nothing selected--look at typing attrs
			attrs = [self typingAttributes];
		}
		
		BOOL menuItemState = NO;
		if (action == @selector(defaultStyle:)) {
			menuItemState = [attrs isEqualToDictionary:[prefsController noteBodyAttributes]];
		} else if (action == @selector(bold:)) {
			menuItemState = [attrs attributesHaveFontTrait:NSBoldFontMask orAttribute:NSStrokeWidthAttributeName];
		} else if (action == @selector(italic:)) {
			menuItemState = [attrs attributesHaveFontTrait:NSItalicFontMask orAttribute:NSObliquenessAttributeName];
		} else if (action == @selector(underlineNV:)) {
			menuItemState = [attrs attributesHaveFontTrait:0 orAttribute:NSUnderlineStyleAttributeName];
		}
		
		if (menuItemState && multipleAttributes)
			menuItemState = NSMixedState;
		[menuItem setState:menuItemState];

		return YES;
	}
	
	return [super validateMenuItem:menuItem];
}

/*
 > Manipulate the text storage directly.  Iterate over it by effective
 > ranges for NSFontAttributeName, making your changes.  Be sure to call
 > -[NSTextView shouldChangeTextInRange:replacementString:] first, then
 > -[NSTextStorage beginEditing], then make your changes, then call
 > -[NSTextStorage endEditing] and -[NSTextView didChangeText].
 */
- (void)defaultStyle:(id)sender {
	NSRange range = [self selectedRange];
	
	if (range.length > 0 && range.location != NSNotFound && 
		[self shouldChangeTextInRange:range replacementString:nil]) {
		
		NSTextStorage *textStorage = [self textStorage];
		[textStorage beginEditing];
		
		[textStorage setAttributes:[prefsController noteBodyAttributes] range:range];
		[textStorage addLinkAttributesForRange:range];
		
		[textStorage endEditing];
		[self didChangeText];
	}
	
	[self setTypingAttributes:[prefsController noteBodyAttributes]];
	
	[[self undoManager] setActionName:NSLocalizedString(@"Plain Text Style",nil)];
}

/*- (void)suggestComplete:(id)sender {
	NSRange selectedRange = [self selectedRange];
	NSRange lastWordRange = [self rangeOfWordLocation:selectedRange.location String:[self string] Backwards:YES];
	if ([self selectedRange].location == lastWordRange.location + lastWordRange.length) {
		[self complete:sender];
	}
}*/

- (id)highlightLinkAtIndex:(unsigned)givenIndex {
	unsigned totalLength = [[self string] length];
	unsigned charIndex = givenIndex;
	if (charIndex >= totalLength)
		charIndex = totalLength - 1;

	NSRange linkRange, maxRange = NSMakeRange(0, totalLength);
	id aLink = [[self textStorage] attribute:NSLinkAttributeName atIndex:charIndex longestEffectiveRange:&linkRange inRange:maxRange];
	
	if (aLink && linkRange.length && NSMaxRange(linkRange) <= maxRange.length)
		[self setAutomaticallySelectedRange:linkRange];
	return aLink;
}

- (void)clickedOnLink:(id)aLink atIndex:(NSUInteger)charIndex {
	NSEvent *currentEvent = [[self window] currentEvent];
	
	if (![prefsController URLsAreClickable] && [currentEvent modifierFlags] & NSCommandKeyMask) {
		
		[self highlightLinkAtIndex:charIndex];
		
	} else if (![prefsController URLsAreClickable]) {
		//pass normal mousedown?
		[self setSelectedRange:NSMakeRange(charIndex, 0)];
		return;
	}
	
	[super clickedOnLink:aLink atIndex:charIndex];
}

- (void)didChangeText {
	/*NSString *string = [self string];
	WordEnumerator *enumerator = [WordEnumerator enumeratorForString:[string substringWithRange:changedRange]];
	NSRange firstWordRange = [enumerator next];
	if (firstWordRange.location != NSNotFound) {
		firstWordRange.location += changedRange.location;
		id link = [[self textStorage] attribute:NSLinkAttributeName atIndex:firstWordRange.location effectiveRange:NULL];
		if ([link isKindOfClass:[NSURL class]]) {
			link = [link absoluteURL];
		}
		
		NSString *word = [string substringWithRange:firstWordRange];
		if (!link || ![link isEqual:word]) {
			firstWordRange.location = NSNotFound;
		}
	}*/
	
	[[self textStorage] removeAttribute:NSLinkAttributeName range:changedRange];
	
	/*if (firstWordRange.location != NSNotFound) {
		[self createWikiLinkWithRange:firstWordRange];
		changedRange.length += changedRange.location - (firstWordRange.location+firstWordRange.length);
		changedRange.location = firstWordRange.location + firstWordRange.length;
	}*/
	
	[[self textStorage] addLinkAttributesForRange:changedRange];
	
	if ([prefsController linksAutoSuggested]) {
		
		/*WordEnumerator *words = [WordEnumerator enumeratorForString:[string substringWithRange:changedRange]];
		NSRange wordRange = [words next];
		while (wordRange.location != NSNotFound) {
			wordRange.location += changedRange.location;
			if ([self isWikiWord: [string substringWithRange:wordRange]]) {
				[self createWikiLinkWithRange: wordRange];
			}
			wordRange = [words next];
		}*/
		
		//[self suggestComplete:nil];
		//[self complete:nil];
	}
	
	//[[self window] invalidateCursorRectsForView:self];
	
	[super didChangeText];
	
	//if the result of changing the text caused us to move into the automatic range, then temporarily ignore the automatic range
	//don't use -selectedRangeWasAutomatic: as it consults didRenderFully, which might not be true here
	if (NSEqualRanges(lastAutomaticallySelectedRange, [self selectedRange]))
		didChangeIntoAutomaticRange = YES;
}

- (BOOL)shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString {
	NSCharacterSet *separatorCharacterSet = [NSAttributedString antiURLCharacterSet];
	
	//it's not exactly proper to alter typing attributes when we don't yet know whether the text should actually be changed, but NV shouldn't cause that to happen, anyway
	[self fixTypingAttributesForSubstitutedFonts];
	
	NSString *string = [self string];
	
	//changedRange = NSMakeRange(affectedCharRange.location, affectedCharRange.length);
	
	NSUInteger begin = [string rangeOfCharacterFromSet:separatorCharacterSet options:NSBackwardsSearch
										  range:NSMakeRange(0, affectedCharRange.location)].location;
	if (begin == NSNotFound) {
		begin = 0;
	}
	
	NSUInteger end = [string rangeOfCharacterFromSet:separatorCharacterSet options:0
										range:NSMakeRange(affectedCharRange.location + affectedCharRange.length, 
														  [string length] - (affectedCharRange.location + affectedCharRange.length))].location;
	if (end == NSNotFound) {
		end = [string length];
	}
	
	changedRange = NSMakeRange(begin, (end-begin));
	
	//NSAttributedString *changedText = [[self textStorage] attributedSubstringFromRange:changedRange];
	changedRange.length += [replacementString length];
	
	/*int startIndex = 0;
	NSRange range;
	while (startIndex < [changedText length]) {
		id link = [changedText findNextLinkAtIndex:startIndex effectiveRange:&range];
		if ([link isKindOfClass:[NSURL class]]) {
			link = [link absoluteString];
		}
		startIndex = range.location+range.length;
	}*/
	
	if (affectedCharRange.length > 0) { // Deleting something
		changedRange.length -= affectedCharRange.length;
	}
	
	return [super shouldChangeTextInRange:affectedCharRange replacementString:replacementString];
}

#ifdef notyet
static long (*GetGetScriptManagerVariablePointer())(short) {
	static long (*_GetScriptManagerVariablePointer)(short) = NULL;
	if (!_GetScriptManagerVariablePointer) {
		NSLog(@"looking up");
		CFBundleRef csBundle = CFBundleCreate(NULL, CFURLCreateWithFileSystemPath(NULL, CFSTR("/System/Library/Frameworks/CoreServices.framework"), kCFURLPOSIXPathStyle, TRUE));
		if (csBundle) _GetScriptManagerVariablePointer = (long (*)(short))CFBundleGetDataPointerForName(csBundle, CFSTR("GetScriptManagerVariable"));
	}
	return _GetScriptManagerVariablePointer;
}
#endif

- (void)fixTypingAttributesForSubstitutedFonts {
	//fixes a problem with fonts substituted by non-system input languages that Apple should have fixed themselves
	
	//if the user has chosen a default font that does not support the current input script, and then changes back to a language input that _does_
	//then the font in the typing attributes will be changed back to match. the problem is that this change occurs only upon changing the input language
	//if the user starts typing in the middle of a block of font-substituted text, the typing attributes will change to that font
	//the result is that typing english in the middle of a block of japanese will use Hiragino Kaku Gothic instead of whatever else the user had chosen
	//this method detects these types of spurious font-changes and reverts to the default font, but only if the font would not be immediately switched back
	//as a result of continuing to type in the native script.
	
	//we'd ideally check smKeyScript against available scripts of current note body font:
	//call RevertTextEncodingToScriptInfo on ATSFontFamilyGetEncoding(ATSFontFamilyFindFromName(CFStringRef([bodyFont familyName]), kATSOptionFlagsDefault))
	//because someone on a japanese-localized system could see their font changing around a lot if they didn't set their note body font to something suitable for their language
	
	BOOL currentKeyboardInputIsSystemLanguage = NO;
	
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
    TISInputSourceRef inputRef = TISCopyCurrentKeyboardInputSource();
    NSArray* inputLangs = [[(NSArray*)TISGetInputSourceProperty(inputRef, kTISPropertyInputSourceLanguages) retain] autorelease];
    CFRelease(inputRef);
    NSString *preferredLang = [[NSLocale autoupdatingCurrentLocale] objectForKey:NSLocaleLanguageCode];
    currentKeyboardInputIsSystemLanguage = nil != preferredLang && [inputLangs containsObject:preferredLang];
#else
	currentKeyboardInputIsSystemLanguage = GetScriptManagerVariable(smSysScript) == GetScriptManagerVariable(smKeyScript);
#endif
	
	if (currentKeyboardInputIsSystemLanguage) {
		//only attempt to restore fonts (with styles of course) if the current script is system default--that is, not using an input method that would change the font
		//this check helps prevent NSTextView from being repeatedly punched in the face when it can't help it
		
		NSFont *currentFont = [prefsController noteBodyFont];
		if (![[[[self typingAttributes] objectForKey:NSFontAttributeName] familyName] isEqualToString:[currentFont familyName]]) {
			//if someone managed to mangle the font--possibly with characters not present in it due to alt. text encoding--so mangle it back
			
			NSMutableDictionary *newTypingAttributes = [[self typingAttributes] mutableCopy];
			[newTypingAttributes setObject:currentFont forKey:NSFontAttributeName];
			//NSLog(@"mangling font 'back' to normal");
			
			if ([[self typingAttributes] attributesHaveFontTrait:NSBoldFontMask orAttribute:NSStrokeWidthAttributeName]) {
				[newTypingAttributes applyStyleInverted:NO trait:NSBoldFontMask forFont:currentFont 
								 alternateAttributeName:NSStrokeWidthAttributeName 
								alternateAttributeValue:[NSNumber numberWithFloat:STROKE_WIDTH_FOR_BOLD]];
				
				currentFont = [newTypingAttributes objectForKey:NSFontAttributeName];
			}
			
			if ([[self typingAttributes] attributesHaveFontTrait:NSItalicFontMask orAttribute:NSObliquenessAttributeName]) {
				[newTypingAttributes applyStyleInverted:NO trait:NSItalicFontMask forFont:currentFont 
								 alternateAttributeName:NSObliquenessAttributeName 
								alternateAttributeValue:[NSNumber numberWithFloat:OBLIQUENESS_FOR_ITALIC]];	
			}
			[self setTypingAttributes:newTypingAttributes];
		}
	}
}

- (void)insertNewline:(id)sender {
	[super insertNewline:sender];
	// If we should indent automatically, check the previous line and scan all the whitespace at the beginning of the line into a string and insert that string into the new line
	//NSString *lastLineString = [[self string] substringWithRange:[[self string] lineRangeForRange:NSMakeRange([self selectedRange].location - 1, 0)]];
	NSString *previousLineWhitespaceString;
	NSScanner *previousLineScanner = [[NSScanner alloc] initWithString:[[self string] substringWithRange:[[self string] lineRangeForRange:NSMakeRange([self selectedRange].location - 1, 0)]]];
	[previousLineScanner setCharactersToBeSkipped:nil];		
	if ([previousLineScanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&previousLineWhitespaceString]) {
		[self insertText:previousLineWhitespaceString];
	}
	[previousLineScanner release];
}

- (void)insertPassword:(NSString*)password
{
    [self insertText:password];
    @try {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    #if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
    NSPasteboardItem *pbitem = [[[NSPasteboardItem alloc] init] autorelease];
    [pbitem setData:password forType:@"public.plain-text"];
    [pb writeObjects:[NSArray arrayWithObject:pbitem]];
    #else
    [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [pb setString:password forType:NSStringPboardType];
    #endif
    } @catch (NSException *e) {}
}

- (void)insertGeneratedPassword:(id)sender {
    NSString *password = [NVPasswordGenerator strong];
    [self insertPassword:password];
}

- (void)showGeneratedPasswords:(id)sender {
    #ifdef notyet
    NSArray *suggestedPasswords = [NVPasswordGenerator suggestions];
    
    // display modal overlay, get user selection and insert it
    // Nice to have:
    // keep stats on the user's selection and then use the most frequent choice in [insertGeneratedPassword] (instead of just [strong])
    #lse
    [self insertGeneratedPassword:nil];
    #endif
}

@end
