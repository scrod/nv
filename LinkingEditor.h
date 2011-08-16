/* LinkingEditor */

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


#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

@class NotesTableView;
@class NoteObject;
@class GlobalPrefs;
//@class ETTransparentScroller;

@interface LinkingEditor : NSTextView
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6
<NSLayoutManagerDelegate>
#endif
{	
    IBOutlet NSTextField *controlField;
    IBOutlet NotesTableView *notesTableView;
	
	//ETTransparentScroller *nvTextScroller;
	GlobalPrefs *prefsController;
	BOOL didRenderFully;
	
	BOOL didChangeIntoAutomaticRange;
	NSRange lastAutomaticallySelectedRange;
	NSRange changedRange;
	BOOL isAutocompleting, wasDeleting;
	
	BOOL backgroundIsDark, mouseInside;
	
	//ludicrous ivars used to hack NSTextFinder. just write your own, damnit!
	NSRange selectedRangeDuringFind;
	NSString *lastImportedFindString;
	NSString *stringDuringFind;
	NoteObject *noteDuringFind;
	
	IMP defaultIBeamCursorIMP, whiteIBeamCursorIMP;
}
//- (IBAction)performNVFindPanelAction:(id)sender;
- (NSColor*)_insertionPointColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor;
- (NSColor*)_linkColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor;
- (NSColor*)_selectionColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor;
- (NSDictionary*)preferredLinkAttributes;
- (void)updateTextColors;
- (NSRange)selectedRangeWasAutomatic:(BOOL*)automatic;
- (void)setAutomaticallySelectedRange:(NSRange)newRange;
- (void)removeHighlightedTerms;
- (void)highlightRangesTemporarily:(CFArrayRef)ranges;
- (NSRange)highlightTermsTemporarilyReturningFirstRange:(NSString*)typedString avoidHighlight:(BOOL)noHighlight;
- (void)defaultStyle:(id)sender;
- (void)strikethroughNV:(id)sender;
- (void)bold:(id)sender;
- (void)italic:(id)sender;
- (void)applyStyleOfTrait:(NSFontTraitMask)trait alternateAttributeName:(NSString*)attrName alternateAttributeValue:(id)value;
- (id)highlightLinkAtIndex:(unsigned)givenIndex;

- (BOOL)jumpToRenaming;
- (void)indicateRange:(NSValue*)rangeValue;

- (void)fixTypingAttributesForSubstitutedFonts;
- (void)fixCursorForBackgroundUpdatingMouseInside:(BOOL)setMouseInside;

- (BOOL)_selectionAbutsBulletIndentRange;
- (BOOL)_rangeIsAutoIdentedBullet:(NSRange)aRange;

- (void)setupFontMenu;

- (BOOL)didRenderFully;

//elasticwork
- (void)switchFindPanelDelegate;
- (IBAction)findInFullscreen;
- (IBAction)insertLink:(id)sender;
//
@end

@interface NSTextView (Private)
#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_6
- (void)toggleAutomaticTextReplacement:(id)sender;
- (BOOL)isAutomaticTextReplacementEnabled;
- (void)setAutomaticTextReplacementEnabled:(BOOL)flag;
- (void)moveToLeftEndOfLine:(id)sender;
#endif

@end
