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

//#import "ETTransparentScroller.h"
#import "LinkingEditor.h"
#import "GlobalPrefs.h"
#import "AppController.h"
#import "AppController_Importing.h"
#import "NotesTableView.h"
#import "NSTextFinder.h"
#import "LinkingEditor_Indentation.h"
#import "NSCollection_utils.h"
#import "AttributedPlainText.h"
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


@interface NSCursor (WhiteIBeamCursor)
+ (NSCursor*)whiteIBeamCursor;
@end

@implementation NSCursor (WhiteIBeamCursor)

+ (NSCursor*)whiteIBeamCursor {
	static NSCursor *invertedIBeamCursor = nil;
	if (!invertedIBeamCursor) {
		invertedIBeamCursor = [[NSCursor alloc] initWithImage:[NSImage imageNamed:@"IBeamInverted"] hotSpot:NSMakePoint(4,5)];
	}
	return invertedIBeamCursor;	
}

@end


@implementation LinkingEditor

CGFloat _perceptualDarkness(NSColor*a);

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
	 @selector(setSearchTermHighlightColor:sender:),
	 @selector(setShouldHighlightSearchTerms:sender:), nil];	
	// @selector(setBackgroundTextColor:sender:),
	// @selector(setForegroundTextColor:sender:),
	
	[self setTextContainerInset:NSMakeSize(3, 8)];
	[self setSmartInsertDeleteEnabled:NO];
	[self setUsesRuler:NO];
	[self setUsesFontPanel:NO];
	[self setDrawsBackground:NO];
    
	[self updateTextColors];
	[[self window] setAcceptsMouseMovedEvents:YES];
	if (IsLeopardOrLater) {
		defaultIBeamCursorIMP = method_getImplementation(class_getClassMethod([NSCursor class], @selector(IBeamCursor)));
		whiteIBeamCursorIMP = method_getImplementation(class_getClassMethod([NSCursor class], @selector(whiteIBeamCursor)));
	}
	
	didRenderFully = NO;
	[[self layoutManager] setDelegate:self];
	
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(windowBecameOrResignedMain:) name:NSWindowDidBecomeMainNotification object:[self window]];
	[center addObserver:self selector:@selector(windowBecameOrResignedMain:) name:NSWindowDidResignMainNotification object:[self window]];
	//[center addObserver:self selector:@selector(updateTextColors) name:NSSystemColorsDidChangeNotification object:nil]; // recreate gradient if needed
//	NoMods = YES;
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
		
	//} else if ([selectorString isEqualToString:SEL_STR(setBackgroundTextColor:sender:)]) {
		
		//link-color is derived both from foreground and background colors
		//[self updateTextColors];
		
	//} else if ([selectorString isEqualToString:SEL_STR(setForegroundTextColor:sender:)]) {
		
		//[self updateTextColors];
		//[self setTypingAttributes:[prefsController noteBodyAttributes]];
		
	} else if ([selectorString isEqualToString:SEL_STR(setSearchTermHighlightColor:sender:)] || 
			   [selectorString isEqualToString:SEL_STR(setShouldHighlightSearchTerms:sender:)]) {
		
		if (![prefsController highlightSearchTerms]) {
			[self removeHighlightedTerms];
		} else {
			NSString *typedString = [[NSApp delegate] typedString];
			if (typedString)
				[self highlightTermsTemporarilyReturningFirstRange:typedString avoidHighlight:NO];
		}
	}
}

- (BOOL)becomeFirstResponder {
	[notesTableView setShouldUseSecondaryHighlightColor:YES];

	if ([[[self window] currentEvent] type] == NSKeyDown && [[[self window] currentEvent] firstCharacter] == '\t') {
		//"indicate" the current cursor/selection when moving focus to this field, but only if the user did not click here
		NSRange range = [self selectedRange];
		if (range.length) {
			range = NSMakeRange(MIN([[self string] length] - 1, range.location), range.length);
			[self performSelector:@selector(indicateRange:) withObject:[NSValue valueWithRange:range] afterDelay:0];
		}
	}
	
	[self setTypingAttributes:[prefsController noteBodyAttributes]];
	
	[self performSelector:@selector(_fixCursorForBackgroundUpdatingMouseInside:) withObject:[NSNumber numberWithBool:YES] afterDelay:0.0];
	
	return [super becomeFirstResponder];
}

- (void)indicateRange:(NSValue*)rangeValue {
	if (IsLeopardOrLater) {
		[self showFindIndicatorForRange:[rangeValue rangeValue]];
	}
}

- (BOOL)resignFirstResponder {
	[notesTableView setShouldUseSecondaryHighlightColor:NO];
	
	[self performSelector:@selector(_fixCursorForBackgroundUpdatingMouseInside:) withObject:[NSNumber numberWithBool:YES] afterDelay:0.0];
	
	return [super resignFirstResponder];
}

- (void)changeColor:(id)sender {
	//NSLog(@"You do not change the color.");
	return;
}

- (void)setBackgroundColor:(NSColor*)aColor {
//	backgroundIsDark = (_perceptualDarkness([aColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace]) > 0.5);
//	[super setBackgroundColor:aColor];
}

- (void)updateTextColors {
	NSColor *fgColor = [[NSApp delegate] foregrndColor];
	NSColor *bgColor = [[NSApp delegate] backgrndColor];
	//[self setBackgroundColor:bgColor];
	//[nvTextScroller setBackgroundColor:bgColor];
	//[[self enclosingScrollView] setNeedsDisplay:YES];
	[self setInsertionPointColor:[self _insertionPointColorForForegroundColor:fgColor backgroundColor:bgColor]];
	[self setLinkTextAttributes:[self preferredLinkAttributes]];
	[self setSelectedTextAttributes:[NSDictionary dictionaryWithObject:[self _selectionColorForForegroundColor:fgColor backgroundColor:bgColor] 
																forKey:NSBackgroundColorAttributeName]];
	[self setTypingAttributes:[prefsController noteBodyAttributes]];
}

#define _CM(__ch) ((__ch) * 255.0)
CGFloat _perceptualDarkness(NSColor*a) {
	//0 to 1; the higher the darker
	
	CGFloat aRed, aGreen, aBlue;
	[a getRed:&aRed green:&aGreen blue:&aBlue alpha:NULL];

	return 1 - (0.299 * _CM(aRed) + 0.587 * _CM(aGreen) + 0.114 * _CM(aBlue))/255;
}
CGFloat _perceptualColorDifference(NSColor*a, NSColor*b) {
	//acceptable: 500
	CGFloat aRed, aGreen, aBlue, bRed, bGreen, bBlue;
	[a getRed:&aRed green:&aGreen blue:&aBlue alpha:NULL];
	[b getRed:&bRed green:&bGreen blue:&bBlue alpha:NULL];

	return (MAX(_CM(aRed), _CM(bRed)) - MIN(_CM(aRed), _CM(bRed))) + (MAX(_CM(aGreen), _CM(bGreen)) - MIN(_CM(aGreen), _CM(bGreen))) + 
	(MAX(_CM(aBlue), _CM(bBlue)) - MIN(_CM(aBlue), _CM(bBlue)));
}

- (NSColor*)_linkColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor {
	//if fgColor is black, choose blue; otherwise, rotate hue (keeping the same sat.) until color is different enough
	
	fgColor = [fgColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
	bgColor = [bgColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
	
	CGFloat hue, brightness, saturation, alpha, diffInc = 0.5;
	NSUInteger rotationsLeft = 25;
	[fgColor getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];

	//if foreground color is too dark for hue changes to matter, then just use blue
	if (brightness <= 0.24)
		return [NSColor blueColor];
	
	brightness = _perceptualDarkness(bgColor) > 0.5 ? MAX(0.75, brightness) : MIN(0.35, brightness);
	
	saturation = MAX(0.5, saturation);
	
	//adjust hue until the perceptual differences between the proposed link
	//and current foreground and background colors are great enough
	NSColor *proposedLinkColor = nil;
	do {
		hue -= diffInc;
		if (hue < 0.0)
			hue += 1.0;
		
		proposedLinkColor = [NSColor colorWithCalibratedHue:hue saturation:saturation brightness:brightness alpha:alpha];
		
		diffInc = rotationsLeft > 15 ? 0.125 : 0.0625;
		
	} while ((_perceptualColorDifference(proposedLinkColor, bgColor) < 360.0 || 
			  _perceptualColorDifference(proposedLinkColor, fgColor) < 170.0) && --rotationsLeft > 0);
	return proposedLinkColor;
}

- (NSColor*)_selectionColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor {
	fgColor = [fgColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
	bgColor = [bgColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];

	NSColor *proposedBlend = [fgColor blendedColorWithFraction:0.5 ofColor:bgColor];
	NSColor *defaultColor = [[NSColor selectedTextBackgroundColor] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
	
	float fgDiff = _perceptualColorDifference(proposedBlend, fgColor);
	float fgSelDiff = _perceptualColorDifference(defaultColor, fgColor);
	
	//selection color should be between foreground and background in terms of brightness
	//but the selection-color-difference from the foreground text needs to be great enough as well,
	//and the proposed-color-difference from the foreground can't be too poor
	//this heuristic chooses all the system-highlight colors in default fg/bg combinations and fg/bg blends in all others
	
//	NSLog(@"fg diff of proposed: %g fg diff of sel: %g", fgDiff, fgSelDiff);
	if ((_perceptualDarkness(fgColor) > _perceptualDarkness(defaultColor) && 
		 _perceptualDarkness(defaultColor) > _perceptualDarkness(bgColor) && fgSelDiff > 300.0) || fgDiff < 170.0)
		return defaultColor;
	
	//amplify the background balance after testing
	return [fgColor blendedColorWithFraction:0.69 ofColor:bgColor];
}


- (NSColor*)_insertionPointColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor {
	fgColor = [fgColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
	bgColor = [bgColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];

	CGFloat hue, brightness, saturation;
	[fgColor getHue:&hue saturation:&saturation brightness:&brightness alpha:NULL];
	
	//make the insertion point lighter than the foreground color if the background is dark and vise versa
	NSColor *brighter = [fgColor blendedColorWithFraction:0.4 ofColor:[NSColor whiteColor]];
	NSColor *darker = [fgColor blendedColorWithFraction:0.4 ofColor:[NSColor blackColor]];

	return _perceptualColorDifference(brighter, bgColor) > _perceptualColorDifference(darker, bgColor) ? brighter : darker;
}

- (NSDictionary*)preferredLinkAttributes {
	if (![prefsController URLsAreClickable])
		return [NSDictionary dictionary];
	
	return [NSDictionary dictionaryWithObjectsAndKeys:
			[NSCursor pointingHandCursor], NSCursorAttributeName,
			[NSNumber numberWithInt:NSUnderlineStyleSingle], NSUnderlineStyleAttributeName,
			[self _linkColorForForegroundColor:[[NSApp delegate] foregrndColor] backgroundColor:[[NSApp delegate] backgrndColor]],
			NSForegroundColorAttributeName, nil];
	
	/*
	 return [NSDictionary dictionaryWithObjectsAndKeys:
	 [NSCursor pointingHandCursor], NSCursorAttributeName,
	 [NSNumber numberWithInt:NSUnderlineStyleSingle], NSUnderlineStyleAttributeName,
	 [self _linkColorForForegroundColor:[prefsController foregroundTextColor] backgroundColor:[prefsController backgroundTextColor]],
	 NSForegroundColorAttributeName, nil];
	 */
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

- (BOOL)didRenderFully {
	return didRenderFully;
}

- (void)layoutManager:(NSLayoutManager *)aLayoutManager didCompleteLayoutForTextContainer:(NSTextContainer *)aTextContainer atEnd:(BOOL)flag {
	didRenderFully = YES;
}
- (void)layoutManagerDidInvalidateLayout:(NSLayoutManager *)aLayoutManager {
	didRenderFully = NO;	
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard type:(NSString *)type {
	//NSLog(@"readSelectionFromPasteboard: %@ (total %@)", type, [[pboard types] description]);
	
	if ([type isEqualToString:NSFilenamesPboardType]) {
		//paste as a file:// URL, so that it can be linked
		NSString *allURLsString = [[NSApp delegate] stringWithNoteURLsOnPasteboard:pboard];
		
		if ([allURLsString length]) {
			NSRange selectedRange = [self rangeForUserTextChange];
			if ([self shouldChangeTextInRange:selectedRange replacementString:allURLsString]) {
				[self replaceCharactersInRange:selectedRange withString:allURLsString];
				[self didChangeText];
				
				return YES;
			}
		}
	}
	
	if ([type isEqualToString:NSRTFPboardType] || [type isEqualToString:NVPTFPboardType] || [type isEqualToString:NSHTMLPboardType]) {
		//strip formatting if RTF and stick it into a new pboard
		
		NSMutableAttributedString *newString = [[[NSMutableAttributedString alloc] performSelector:[type isEqualToString:NSHTMLPboardType] ? 
												 @selector(initWithHTML:documentAttributes:) : @selector(initWithRTF:documentAttributes:) 
																						withObject:[pboard dataForType:type] withObject:nil] autorelease];
		if ([newString length]) {
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
		[types insertObject:NSHTMLPboardType atIndex:3];
	}
	
	return types;
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard type:(NSString *)type {
	
	if ([type isEqualToString:NVPTFPboardType] || [type isEqualToString:NSRTFPboardType]) {
		//always preserve RTF to allow pasting into ourselves; prejudice against external sources
		
		NSMutableAttributedString *newString = [[[self textStorage] attributedSubstringFromRange:[self selectedRange]] mutableCopy];
		
		if (![type isEqualToString:NVPTFPboardType])
			[newString removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [newString length])];

		NSData *rtfData = [newString RTFFromRange:NSMakeRange(0, [newString length]) documentAttributes:nil];;
		if (rtfData) [pboard setData:rtfData forType:type];
		[newString release];
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
				if ([attributes attributesHaveFontTrait:0 orAttribute:NSStrikethroughStyleAttributeName])
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

//font panel is disabled for the note-body, so styles must be applied manually:

- (void)strikethroughNV:(id)sender {

	[self applyStyleOfTrait:0 alternateAttributeName:NSStrikethroughStyleAttributeName 
	alternateAttributeValue:[NSNumber numberWithInt:NSUnderlineStyleSingle]];
	
	[[self undoManager] setActionName:NSLocalizedString(@"Strikethrough",nil)];
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

- (NSRange)highlightTermsTemporarilyReturningFirstRange:(NSString*)typedString avoidHighlight:(BOOL)noHighlight {
	
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
						if (firstRange.location > (NSUInteger)range->location) {
							firstRange = *(NSRange*)range;
							if (noHighlight) {
								CFRelease(ranges);
								goto returnEarly;
							}
						}
						[[self layoutManager] addTemporaryAttributes:highlightDict forCharacterRange:*(NSRange*)range];
					} else {
						NSLog(@"highlightTermsTemporarily: Invalid range (%@)", range ? NSStringFromRange(*(NSRange*)range) : @"?");
					}
				}
				CFRelease(ranges);
			}
		}
	returnEarly:
		CFRelease(terms);
	}
	return (firstRange);
}

- (NSRange)selectionRangeForProposedRange:(NSRange)proposedSelRange granularity:(NSSelectionGranularity)granularity {
    
   // [[NSApp delegate] updateWordCount:YES];
	if (granularity != NSSelectByWord || [[self string] length] == proposedSelRange.location) {
		// If it's not a double-click return unchanged
		return [super selectionRangeForProposedRange:proposedSelRange granularity:granularity];
	}
	
	unsigned int location = (unsigned int)[super selectionRangeForProposedRange:proposedSelRange granularity:NSSelectByCharacter].location;
	int originalLocation = location;
	
	NSString *completeString = [self string];
	unichar characterToCheck = [completeString characterAtIndex:location];
	unsigned short skipMatchingBrace = 0;
	unsigned int lengthOfString = (unsigned int)[completeString length];
	if (lengthOfString == proposedSelRange.location) { // To avoid crash if a double-click occurs after any text
		return [super selectionRangeForProposedRange:proposedSelRange granularity:granularity];
	}
	
	BOOL triedToMatchBrace = NO;
	
	char *rightGroupings = ")}]>";
	char *leftGroupings = "({[<";
	int groupingIndex = 0;
	
	char *rightChar = strchr(rightGroupings, (char)characterToCheck);
	if (rightChar) {
		groupingIndex = (int)(rightChar - rightGroupings);
		
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
		groupingIndex = (int)(leftChar - leftGroupings);
		
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
/*
- (IBAction)performNVFindPanelAction:(id)sender {
	//NSLog(@"finding sender is :%@",[sender description]);
	[[self window] endEditingFor:nil]; 
	[self setUsesFindPanel:YES];
	[super performFindPanelAction:sender];
}*/

- (IBAction)performFindPanelAction:(id)sender {
	id controller = [NSApp delegate];
    NSString *typedString = [controller typedString];
	NSString *currentFindString = nil;
	
    if (!typedString) typedString = [controlField stringValue];
	typedString = [typedString stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    
    NSTextFinder *textFinder = [NSTextFinder sharedTextFinder];
	
	[self switchFindPanelDelegate];
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
	
	//[textFinder setTextObjectToSearchIn:self];
	[super performFindPanelAction:sender];
	//NSLog(@"textfienders win resp: %@",[[[textFinder findPanel:YES] firstResponder]description]);NSFindPanelTextView
	[stringDuringFind release];
	stringDuringFind = [currentFindString retain];
	noteDuringFind = [controller selectedNoteObject];
	selectedRangeDuringFind = [self selectedRange];
	lastAutomaticallySelectedRange = selectedRangeDuringFind;
}

- (BOOL)performKeyEquivalent:(NSEvent *)anEvent {
    [[NSApp delegate] resetModTimers];
	if ([anEvent modifierFlags] & NSCommandKeyMask) {
		
		unichar keyChar = [anEvent firstCharacterIgnoringModifiers];
		if (keyChar == NSCarriageReturnCharacter || keyChar == NSNewlineCharacter || keyChar == NSEnterCharacter) {
		//	NSLog(@"insertion");
			unsigned charIndex = [self selectedRange].location;
			
			id aLink = [self highlightLinkAtIndex:charIndex];
			if ([aLink isKindOfClass:[NSURL class]]) {
				[self clickedOnLink:aLink atIndex:charIndex];
				return YES;
			}
		} else if ((keyChar == NSBackspaceCharacter || keyChar == NSDeleteCharacter) && [[self window] firstResponder] == self) {
			if ([[self string] length]) {
				[self doCommandBySelector:@selector(deleteToBeginningOfLine:)];
				return YES;
			}
		}
	}
	
	return [super performKeyEquivalent:anEvent];
}

- (void)flagsChanged:(NSEvent *)theEvent{
	[[NSApp delegate] flagsChanged:theEvent];
}

- (void)keyDown:(NSEvent*)anEvent {	
    [[NSApp delegate] resetModTimers];
	unichar keyChar = [anEvent firstCharacterIgnoringModifiers];

	if (keyChar == NSBackTabCharacter) {
		//apparently interpretKeyEvents: on 10.3 does not call insertBacktab
		//maybe it works on someone else's 10.3 Mac
		[self doCommandBySelector:@selector(insertBacktab:)];
		return;
	}else if (([anEvent keyCode]==36)&&([anEvent modifierFlags]&NSCommandKeyMask)&&(!(([anEvent modifierFlags]&NSControlKeyMask)||([anEvent modifierFlags]&NSAlternateKeyMask)||([anEvent modifierFlags]&NSShiftKeyMask)))) {        
        [self moveToEndOfParagraph:self];
        [self insertNewlineIgnoringFieldEditor:self]; 
		return;
    }
    
    //[super interpretKeyEvents:[NSArray arrayWithObject:anEvent]];
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
	//check temporary NVHiddenBulletIndentAttributeName here first
	if ([prefsController autoFormatsListBullets] && [self _selectionAbutsBulletIndentRange]) {
		
		[self shiftLeftAction:nil];
	} else {
	
		[[self window] selectPreviousKeyView:self];
	}
}

- (void)insertTabIgnoringFieldEditor:(id)sender {
	
	NSRange range = [self selectedRange];
	if ((range.length > 0 && [[self string] rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet] 
														   options:NSLiteralSearch range:range].location != NSNotFound) ||
		([prefsController autoFormatsListBullets] && [self _selectionAbutsBulletIndentRange])) {
		//tab shifts text only if there is more than one line selected (i.e., the selection contains at least one line break), or an indented bullet is near
		
		[self shiftRightAction:nil];
		
	} else if ([prefsController softTabs]) {
		
		int numberOfSpacesPerTab = [prefsController numberOfSpacesInTab];

		int locationOnLine = range.location - [[self string] lineRangeForRange:range].location;
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

- (void)insertText:(id)string {
    BOOL interpretEvent = YES;
    if (([prefsController useAutoPairing])&&([[NSArray arrayWithObjects:@"\"",@"[",@"{",@"(",@"]",@"}",@")", nil] containsObject:string])){
        NSString *appendString = string;
        NSRange selRange = [self selectedRange];
        NSString *postString =@"";
        postString = [[self string] substringFromIndex:selRange.location+selRange.length];
        if (!postString) {
            postString=@"";
        }
        if (([[NSArray arrayWithObjects:@"]",@"}",@")", nil] containsObject:appendString])&&([postString hasPrefix:appendString])&&(selRange.length==0)) {
            interpretEvent=NO;
            selRange.length=1;
            [self setSelectedRange:selRange];
            [super insertText:appendString];
        }else  if ([[NSArray arrayWithObjects:@"\"",@"[",@"{",@"(", nil] containsObject:appendString]){     
             NSString *oppositeAppend = appendString;
            
             if ([appendString isEqualToString:@"["]) {
                 oppositeAppend = @"]";
             }else if ([appendString isEqualToString:@"{"]) {
                 oppositeAppend = @"}";
             }else if ([appendString isEqualToString:@"("]) {
                 oppositeAppend = @")";
             }
            
            interpretEvent=NO; 
            if (([postString hasPrefix:oppositeAppend])&&(![[[self string]substringToIndex:selRange.location] hasSuffix:appendString])) {
                    //NSLog(@"gotchas2");
                    interpretEvent=YES;                 
            }
            if (!interpretEvent) {
                int extra = appendString.length;
                if (selRange.length>0) {
                    NSString *selString = [[self string] substringWithRange:selRange];                 
                    appendString = [NSString stringWithFormat:@"%@%@%@",appendString,selString,oppositeAppend];
                    extra = extra+selString.length+oppositeAppend.length;
                }else {                 
                    if (([appendString isEqualToString:@"\""])&&([postString hasPrefix:@"\""])) {                     
                        appendString = @"";
                        oppositeAppend = @"";
                    }
                    appendString = [appendString stringByAppendingString:oppositeAppend];
                }
                [super insertText:appendString];
                [self setSelectedRange:NSMakeRange(selRange.location+extra, 0)];  
            }
             
        }
    }
    if (interpretEvent){
        [super insertText:string]; 
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
}

*/

- (void)mouseEntered:(NSEvent*)anEvent {
	mouseInside = YES;
	[self fixCursorForBackgroundUpdatingMouseInside:NO];
}
- (void)mouseExited:(NSEvent*)anEvent {
	mouseInside = NO;
	[self fixCursorForBackgroundUpdatingMouseInside:NO];
}

- (void)_fixCursorForBackgroundUpdatingMouseInside:(NSNumber*)num {
	[self fixCursorForBackgroundUpdatingMouseInside:[num boolValue]];
}

- (void)fixCursorForBackgroundUpdatingMouseInside:(BOOL)setMouseInside {
	
	if (IsLeopardOrLater && whiteIBeamCursorIMP && defaultIBeamCursorIMP) {
		if (setMouseInside)
			mouseInside = [self mouse:[self convertPoint:[[self window] mouseLocationOutsideOfEventStream] fromView:nil] inRect:[self bounds]];
		
		BOOL shouldBeWhite = mouseInside && backgroundIsDark && ![self isHidden];
		Class class = [NSCursor class];
		
		//set method implementation directly; whiteIBeamCursorIMP and defaultIBeamCursorIMP always point to the same respective blocks of code
		Method defaultIBeamCursorMethod = class_getClassMethod(class, @selector(IBeamCursor));
		method_setImplementation(defaultIBeamCursorMethod, shouldBeWhite ? whiteIBeamCursorIMP : defaultIBeamCursorIMP);
		
		NSCursor *currentCursor = [NSCursor currentCursor];
		NSCursor *whiteCursor = whiteIBeamCursorIMP(class, @selector(whiteIBeamCursor));
		NSCursor *defaultCursor = defaultIBeamCursorIMP(class, @selector(IBeamCursor));
		
		//if the current cursor is set incorrectly, and and it's not a non-IBeam cursor, then update it (IBeamCursor points to our recently-set implementation)
		if ((currentCursor == whiteCursor) != shouldBeWhite && (currentCursor == whiteCursor || currentCursor == defaultCursor)) {
			[[NSCursor IBeamCursor] set];
		}
	}
}

//hiding or showing the view does not always produce mouseEntered/Exited events
- (void)viewDidUnhide {
	[self performSelector:@selector(_fixCursorForBackgroundUpdatingMouseInside:) withObject:[NSNumber numberWithBool:YES] afterDelay:0.0];

	[super viewDidUnhide];
}
- (void)viewDidHide {
	[self fixCursorForBackgroundUpdatingMouseInside:YES];
	[super viewDidHide];
}

- (void)windowBecameOrResignedMain:(NSNotification *)aNotification  {
	//changing the window ordering seems to occasionally trigger mouseExited events w/o a corresponding mouseEntered
	[self fixCursorForBackgroundUpdatingMouseInside:YES];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
	//need to fix this for better style detection
	
	SEL action = [menuItem action];
	if (action == @selector(defaultStyle:) ||
		action == @selector(bold:) ||
		action == @selector(italic:) ||
		action == @selector(strikethroughNV:)) {
		
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
		} else if (action == @selector(strikethroughNV:)) {
			menuItemState = [attrs attributesHaveFontTrait:0 orAttribute:NSStrikethroughStyleAttributeName];
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
		[textStorage endEditing];
		
		[self didChangeText];
	}
	
	[self setTypingAttributes:[prefsController noteBodyAttributes]];
	
	[[self undoManager] setActionName:NSLocalizedString(@"Plain Text Style",nil)];
}

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
	
	if ([aLink isKindOfClass:[NSURL class]] && [[aLink scheme] isEqualToString:@"nv"]) {
		[[NSApp delegate] interpretNVURL:aLink];
	} else {
		[super clickedOnLink:aLink atIndex:charIndex];
	}
}

- (NSRange)rangeForUserCompletion {
	NSRange completionRange = [super rangeForUserCompletion];
	//NSLog(@"completionRange: %@", [[self string] substringWithRange:completionRange]);
	
	
	//problem: changedRange.location was 201, but completionRange.location was 195
	NSRange beginLineRange = NSMakeRange(changedRange.location, completionRange.location - changedRange.location);
	if (beginLineRange.length > changedRange.length)
		goto cancelCompetion;
	
	NSRange backRange = [[self string] rangeOfString:@"[[" options:NSBackwardsSearch | NSLiteralSearch range:beginLineRange];
	if (backRange.location == NSNotFound)
		goto cancelCompetion;
	
	backRange.location += 2;
	backRange.length = completionRange.length + (completionRange.location - backRange.location);

	if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[[self string] characterAtIndex:backRange.location]])
		goto cancelCompetion;
	
	if ([[self string] rangeOfString:@"]]" options:NSLiteralSearch range:backRange].location != NSNotFound)
		goto cancelCompetion;
		
	return backRange;
cancelCompetion:
	return NSMakeRange(NSNotFound, 0);
}

- (void)insertCompletion:(NSString *)word forPartialWordRange:(NSRange)charRange movement:(NSInteger)movement isFinal:(BOOL)isFinal {
	NSString *str = [self string];
	BOOL finalizedCompletion = NO;
	
	isFinal = isFinal && movement != NSRightTextMovement;
	
	if (isFinal && [word length] && (movement == NSReturnTextMovement || movement == NSTabTextMovement)) {
		
		//automatically add a trailing double-bracket if one does not already exist
		NSRange endRange = NSMakeRange(charRange.location + [word length], 2);
		if ([str length] < NSMaxRange(endRange) || ![[str substringWithRange:endRange] isEqualToString:@"]]"]) {
			word = [word stringByAppendingString:@"]]"];
		}
		finalizedCompletion = YES;
	}
	
	//preserve capitalization by transferring charRange substring into word
	if (!finalizedCompletion && charRange.length <= [word length]) { 
		NSString *existingWord = [str substringWithRange:charRange];
		word = [existingWord stringByAppendingString:[word substringFromIndex:[existingWord length]]];
	}
	
	[super insertCompletion:word forPartialWordRange:charRange movement:movement isFinal:isFinal];
}

- (void)didChangeText {
	
	//if the text storage was somehow shortened since changedRange was set in -shouldChangeText, at least avoid an out of bounds exception
	changedRange = NSMakeRange(changedRange.location, (MIN(NSMaxRange(changedRange), [[self string] length]) - changedRange.location));


	//-removeAttribute:range: seems slow for some reason; try checking with -attributesAtIndex:effectiveRange: first
	if ([[self textStorage] attribute:NSLinkAttributeName existsInRange:changedRange])
		[[self textStorage] removeAttribute:NSLinkAttributeName range:changedRange];
	[[self textStorage] addLinkAttributesForRange:changedRange];
	
	[[self textStorage] addStrikethroughNearDoneTagsForRange:changedRange];
	
	if (!isAutocompleting && !wasDeleting && [prefsController linksAutoSuggested] && 
		![[self undoManager] isUndoing] && ![[self undoManager] isRedoing]) {
		isAutocompleting = YES;
		[self complete:self];
		isAutocompleting = NO;
	}
	
	//[[self window] invalidateCursorRectsForView:self];
	
	[super didChangeText];
	
	//if the result of changing the text caused us to move into the automatic range, then temporarily ignore the automatic range
	//don't use -selectedRangeWasAutomatic: as it consults didRenderFully, which might not be true here
	if (NSEqualRanges(lastAutomaticallySelectedRange, [self selectedRange]))
		didChangeIntoAutomaticRange = YES;
}

- (BOOL)shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString {
	wasDeleting = ![replacementString length];
	
	//it's not exactly proper to alter typing attributes when we don't yet know whether the text should actually be changed, but NV shouldn't cause that to happen, anyway
	[self fixTypingAttributesForSubstitutedFonts];
	
	NSString *string = [self string];
		
	NSCharacterSet *separatorCharacterSet = [NSCharacterSet newlineCharacterSet];
	//even when only seeking newlines, this manual line-finding method is less laggy than -[NSString lineRangeForRange:]
	NSUInteger begin = [string rangeOfCharacterFromSet:separatorCharacterSet options:NSBackwardsSearch range:NSMakeRange(0, affectedCharRange.location)].location;
	if (begin == NSNotFound) {
		begin = 0;
	}
	
	NSUInteger end = [string rangeOfCharacterFromSet:separatorCharacterSet options:0 range:NSMakeRange(affectedCharRange.location + affectedCharRange.length, 
																									   [string length] - (affectedCharRange.location + affectedCharRange.length))].location;
	if (end == NSNotFound) {
		end = [string length];
	}
	changedRange = NSMakeRange(begin, (end - begin) + [replacementString length]);
		
	if (affectedCharRange.length > 0 && replacementString != nil) { // Deleting something
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

- (BOOL)_selectionAbutsBulletIndentRange {

	NSRange range = [self selectedRange];
	NSRange backBulletRange = NSMakeRange(range.location - 2, 2);
	NSRange frontBulletRange = NSMakeRange(range.location, 2);
	
	return ((backBulletRange.location > 0 && NSMaxRange(backBulletRange) < [[self string] length] && [self _rangeIsAutoIdentedBullet:backBulletRange]) || 
			(NSMaxRange(frontBulletRange) < [[self string] length] && [self _rangeIsAutoIdentedBullet:frontBulletRange]));
}

- (BOOL)_rangeIsAutoIdentedBullet:(NSRange)aRange {
	NSRange effectiveRange = NSMakeRange(aRange.location, 0);
	while (NSMaxRange(effectiveRange) < NSMaxRange(aRange)) {
		
		id bulletIndicator = nil;
		
		//sometimes the temporary attributes are split across juxtaposing characters for some reason, so longest-effective-range is necessary
		//unfortunately there is no such method on Tiger, and I'm not about to emulate its coalescing behavior here
		if (IsLeopardOrLater) {
			bulletIndicator = [[self layoutManager] temporaryAttribute:NVHiddenBulletIndentAttributeName atCharacterIndex:NSMaxRange(effectiveRange) 
												 longestEffectiveRange:&effectiveRange inRange:aRange];
		} else {
			NSDictionary *dict = [[self layoutManager] temporaryAttributesAtCharacterIndex:NSMaxRange(effectiveRange) effectiveRange:&effectiveRange];
			bulletIndicator = [dict objectForKey:NVHiddenBulletIndentAttributeName];
		}
		if (bulletIndicator && NSEqualRanges(effectiveRange, aRange)) {
			return YES;
		}
	}
	
	return NO;	
}

- (void)insertNewline:(id)sender {
//	NSLog(@"insertion2");
	//reset custom styles after each line
	[self setTypingAttributes:[prefsController noteBodyAttributes]];
	
	[super insertNewline:sender];
	
	if ([prefsController autoIndentsNewLines]) {
		// If we should indent automatically, check the previous line and scan all the whitespace at the beginning of the line into a string and insert that string into the new line
		NSString *previousLineWhitespaceString = nil;
		NSRange previousLineRange = [[self string] lineRangeForRange:NSMakeRange([self selectedRange].location - 1, 0)];
		NSScanner *previousLineScanner = [[NSScanner alloc] initWithString:[[self string] substringWithRange:previousLineRange]];
		[previousLineScanner setCharactersToBeSkipped:nil];
		
		if ([previousLineScanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&previousLineWhitespaceString]) {
			//for propagating list-element, look for bullet-type-character + 1charWS + at-least-one-nonWSChar
			
			NSUInteger loc = [previousLineScanner scanLocation];
			NSString *str = [previousLineScanner string];
			unichar bulletChar, wsChar;
			NSRange realBulletRange = NSMakeRange(loc + previousLineRange.location, 2), carriedBulletRange = NSMakeRange(NSNotFound, 0);
			BOOL shouldDeleteLastBullet = NO;
			
			if ([prefsController autoFormatsListBullets]) {
				if (loc + 2 < [str length] && ![previousLineScanner isAtEnd] &&
					[[NSCharacterSet listBulletsCharacterSet] characterIsMember:(bulletChar = [str characterAtIndex:loc])] && 
					[[NSCharacterSet whitespaceCharacterSet] characterIsMember:(wsChar = [str characterAtIndex:loc + 1])] &&
					[[[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet] characterIsMember:[str characterAtIndex:loc + 2]]) {
					
					carriedBulletRange = NSMakeRange(NSMaxRange(previousLineRange) + [previousLineWhitespaceString length], 2);
					previousLineWhitespaceString = [previousLineWhitespaceString stringByAppendingFormat:@"%C%C", bulletChar, wsChar];
					
				} else if (NSMaxRange(realBulletRange) < [[self string] length] && [self _rangeIsAutoIdentedBullet:realBulletRange]) {
					//should not carry a bullet; also check if one is here that we should delete
					shouldDeleteLastBullet = YES;
				}
			}
			
			if (shouldDeleteLastBullet) {
				//we had carried a bullet, but now it is no carried no more
				//so instead of inserting the extra space, delete both that previously-carried-bullet and the newline added by -super up there
				[[self textStorage] deleteCharactersInRange:NSMakeRange(realBulletRange.location, realBulletRange.length + 1)];
			} else {
				[self insertText:previousLineWhitespaceString];
				if (carriedBulletRange.length) {
					[[self layoutManager] addTemporaryAttributes:[NSDictionary dictionaryWithObject:[NSNull null] forKey:NVHiddenBulletIndentAttributeName] 
											   forCharacterRange:carriedBulletRange];
					//[[self layoutManager] addTemporaryAttributes:[prefsController searchTermHighlightAttributes] forCharacterRange:carriedBulletRange];
				}
			}
		}
		[previousLineScanner release];
	}
}

- (void)setupFontMenu {
	NSMenu *theMenu = [[[NSMenu alloc] initWithTitle:@"NVFontMenu"] autorelease];
	NSMenuItem *theMenuItem;
	if(IsLeopardOrLater){
        
        theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Enter Full Screen",@"toggle fs menu item title") action:@selector(switchFullScreen:) keyEquivalent:@""] autorelease];
        [theMenuItem setTarget:[NSApp delegate]];
        [theMenu addItem:theMenuItem];         
	}
    theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Insert Link",@"insert link menu item title") action:@selector(insertLink:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[theMenu addItem:theMenuItem];
    [theMenu addItem:[NSMenuItem separatorItem]];
    
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Cut",@"cut menu item title") action:@selector(cut:) keyEquivalent:@""] autorelease];
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
	
	theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Strikethrough",nil) action:@selector(strikethroughNV:) keyEquivalent:@""] autorelease];
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
		theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Insert Link",@"insert link menu item title") action:@selector(insertLink:) keyEquivalent:@"L"] autorelease];
        [theMenuItem setTarget:self];
        [editMenu addItem:theMenuItem];
        
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
	
}

- (void)insertPassword:(NSString*)password
{
    [self insertText:password];
    @try {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    #if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
    NSPasteboardItem *pbitem = [[[NSPasteboardItem alloc] init] autorelease];
    [pbitem setData:[password dataUsingEncoding:NSUTF8StringEncoding] forType:@"public.plain-text"];
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

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	[super dealloc];
}


//elasticwork


- (IBAction)insertLink:(id)sender{
     if ([[self window] firstResponder]!=self) {
         [[self window] makeFirstResponder:self];
    }
    NSRange selRange = [self selectedRange];
    if (selRange.length>0) {
        NSString *selString = [[self string] substringWithRange:selRange];
        selString = [NSString stringWithFormat:@"%@%@%@",@"[[",selString,@"]]"];
        [super insertText:selString];
        
    }else{
        [super insertText:@"[[]]"];
        [self setSelectedRange:NSMakeRange([self selectedRange].location-2, 0)];
    }
    
} 

- (void)switchFindPanelDelegate{
	NSTextFinder *textFinder = [NSTextFinder sharedTextFinder];
    if ([[[self window] contentView] isInFullScreenMode]) {
		[[textFinder findPanel:YES] setDelegate:self];
		NSArray *sViews = [[[textFinder findPanel:YES] contentView] subviews];
		for (id thing in sViews){
			if ([[thing className] isEqualToString:@"NSButton"]) {
				NSButton *aBut = thing;
				if (![aBut target]==nil) {
					[aBut setTarget:self];
					[aBut setAction:@selector(findInFullscreen:)];
				}
			}
		}
	}else {
		[[textFinder findPanel:YES] setDelegate:textFinder];
		NSArray *sViews = [[[textFinder findPanel:YES] contentView] subviews];
		for (id thing in sViews){
			if ([[thing className] isEqualToString:@"NSButton"]) {
				NSButton *aBut = thing;
				if (![aBut target]==nil) {
					[aBut setTarget:textFinder];
					[aBut setAction:@selector(performFindPanelAction:)];
				}
			}
		}
		
	}
	[[textFinder findPanel:YES] update];
}

- (IBAction)findInFullscreen:(id)sender{
	int findTag = 1;
	if ([[sender className] isEqualToString:@"NSButton"]) {
		//NSLog(@"findinfull sender is :%@",[sender title]);
		if ([[sender title] isEqualToString:@"Replace All"]) {
			findTag = 4;
		}else if ([[sender title] isEqualToString:@"Replace"]) {
			findTag = 5;
		}else if ([[sender title] isEqualToString:@"Replace & Find"]) {
			findTag = 6;
		}else if ([[sender title] isEqualToString:@"Replace"]) {
			findTag = 5;
		}else if ([[sender title] isEqualToString:@"Previous"]) {
			findTag = 3;
		}else if ([[sender title] isEqualToString:@"Next"]) {
			findTag = 2;
		}
	}
//	[[NSTextFinder sharedTextFinder] setFindString:[[NSTextFinder sharedTextFinder] findString] writeToPasteboard:NO updateUI:YES];
	[[NSTextFinder sharedTextFinder] performFindPanelAction:findTag forClient:self];
}

- (void)mouseDown:(NSEvent *)theEvent{
    [[NSApp delegate] setIsEditing:NO];
    
    [super mouseDown:theEvent];
}


@end
