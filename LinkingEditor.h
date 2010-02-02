/* LinkingEditor */

#import <Cocoa/Cocoa.h>

@class NotesTableView;
@class NoteObject;
@class GlobalPrefs;

#define DELAYED_LAYOUT 0

@interface LinkingEditor : NSTextView
{
    IBOutlet NSTextField *controlField;
    IBOutlet NotesTableView *notesTableView;

	GlobalPrefs *prefsController;
#if DELAYED_LAYOUT
	NSTimer *timer;
	BOOL inhibitingUpdates;
	BOOL didSetFutureRange, didInvalidateLayout, didRenderFully;
	NSRange futureRange;
	NSString *futureWordsToHighlight;
	unsigned int lastHighlightedIndex;
	NSRect rectForSuppressedUpdate;
#else
	BOOL didRenderFully;
#endif
	
	BOOL didChangeIntoAutomaticRange;
	NSRange lastAutomaticallySelectedRange;
	NSRange changedRange;
	
	//ludicrous ivars used to hack NSTextFinder. just write your own, damnit!
	NSRange selectedRangeDuringFind;
	NSString *lastImportedFindString;
	NSString *stringDuringFind;
	NoteObject *noteDuringFind;
}

- (NSDictionary*)preferredLinkAttributes;
- (NSRange)selectedRangeWasAutomatic:(BOOL*)automatic;
- (void)setAutomaticallySelectedRange:(NSRange)newRange;
- (void)removeHighlightedTerms;
- (void)highlightRangesTemporarily:(CFArrayRef)ranges;
- (NSRange)highlightTermsTemporarilyReturningFirstRange:(NSString*)typedString;
- (void)defaultStyle:(id)sender;
- (void)underlineNV:(id)sender;
- (void)bold:(id)sender;
- (void)italic:(id)sender;
- (void)applyStyleOfTrait:(NSFontTraitMask)trait alternateAttributeName:(NSString*)attrName alternateAttributeValue:(id)value;
//- (void)suggestComplete:(id)sender;
- (id)highlightLinkAtIndex:(unsigned)givenIndex;

- (BOOL)jumpToRenaming;
- (void)indicateRange:(NSValue*)rangeValue;

- (void)fixTypingAttributesForSubstitutedFonts;

#if DELAYED_LAYOUT
- (void)_updateHighlightedRangesToIndex:(unsigned)loc;
- (void)_setFutureSelectionRangeWithinIndex:(unsigned)loc;
- (void)setFutureSelectionRange:(NSRange)aRange highlightingWords:(NSString*)words;
- (BOOL)readyToDraw;
- (void)beginInhibitingUpdates;
#else
- (BOOL)didRenderFully;
#endif
@end

@interface NSTextView (Private)
#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_6
- (void)toggleAutomaticTextReplacement:(id)sender;
- (BOOL)isAutomaticTextReplacementEnabled;
- (void)setAutomaticTextReplacementEnabled:(BOOL)flag;

- (void)moveToLeftEndOfLine:(id)sender;
#endif

- (void)_checkSpellingForRange:(struct _NSRange)fp8 excludingRange:(struct _NSRange)fp16;

@end
