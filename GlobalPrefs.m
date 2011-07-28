//
//  GlobalPrefs.m
//  Notation
//
//  Created by Zachary Schneirov on 1/31/06.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#import "GlobalPrefs.h"
#import "NSData_transformations.h"
#import "NotationPrefs.h"
#import "BookmarksController.h"
#import "AttributedPlainText.h"
#import "FastListDataSource.h"
#import "NotesTableView.h"
#import "PTHotKey.h"
#import "PTKeyCombo.h"
#import "PTHotKeyCenter.h"
#import "NSString_NV.h"
#import "AppController.h"

#define SEND_CALLBACKS() sendCallbacksForGlobalPrefs(self, _cmd, sender)

static NSString *TriedToImportBlorKey = @"TriedToImportBlor";
static NSString *DirectoryAliasKey = @"DirectoryAlias";
static NSString *AutoCompleteSearchesKey = @"AutoCompleteSearches";
static NSString *NoteAttributesVisibleKey = @"NoteAttributesVisible";
static NSString *TableFontSizeKey = @"TableFontPointSize";
static NSString *TableSortColumnKey = @"TableSortColumn";
static NSString *TableIsReverseSortedKey = @"TableIsReverseSorted";
static NSString *TableColumnsHaveBodyPreviewKey = @"TableColumnsHaveBodyPreview";
static NSString *NoteBodyFontKey = @"NoteBodyFont";
static NSString *ConfirmNoteDeletionKey = @"ConfirmNoteDeletion";
static NSString *CheckSpellingInNoteBodyKey = @"CheckSpellingInNoteBody";
static NSString *TextReplacementInNoteBodyKey = @"TextReplacementInNoteBody";
static NSString *QuitWhenClosingMainWindowKey = @"QuitWhenClosingMainWindow";
static NSString *TabKeyIndentsKey = @"TabKeyIndents";
static NSString *PastePreservesStyleKey = @"PastePreservesStyle";
static NSString *AutoFormatsDoneTagKey = @"AutoFormatsDoneTag";
static NSString *AutoFormatsListBulletsKey = @"AutoFormatsListBullets";
static NSString *AutoSuggestLinksKey = @"AutoSuggestLinks";
static NSString *AutoIndentsNewLinesKey = @"AutoIndentsNewLines";
static NSString *HighlightSearchTermsKey = @"HighlightSearchTerms";
static NSString *SearchTermHighlightColorKey = @"SearchTermHighlightColor";
static NSString *ForegroundTextColorKey = @"ForegroundTextColor";
static NSString *BackgroundTextColorKey = @"BackgroundTextColor";
static NSString *UseSoftTabsKey = @"UseSoftTabs";
static NSString *NumberOfSpacesInTabKey = @"NumberOfSpacesInTab";
static NSString *MakeURLsClickableKey = @"MakeURLsClickable";
static NSString *AppActivationKeyCodeKey = @"AppActivationKeyCode";
static NSString *AppActivationModifiersKey = @"AppActivationModifiers";
static NSString *HorizontalLayoutKey = @"HorizontalLayout";
static NSString *BookmarksKey = @"Bookmarks";
static NSString *LastScrollOffsetKey = @"LastScrollOffset";
static NSString *LastSearchStringKey = @"LastSearchString";
static NSString *LastSelectedNoteUUIDBytesKey = @"LastSelectedNoteUUIDBytes";
static NSString *LastSelectedPreferencesPaneKey = @"LastSelectedPrefsPane";
//elasticthreads prefs
static NSString *StatusBarItem = @"StatusBarItem";
static NSString	*HideDockIcon = @"HideDockIcon";
static NSString	*KeepsMaxTextWidth = @"KeepsMaxTextWidth";
static NSString	*NoteBodyMaxWidth = @"NoteBodyMaxWidth";
static NSString	*ColorScheme = @"ColorScheme";
static NSString	*TextEditor = @"TextEditor";
static NSString *UseMarkdownImportKey = @"UseMarkdownImport";
static NSString *UseReadabilityKey = @"UseReadability";
static NSString *ShowGridKey = @"ShowGrid";
static NSString *AlternatingRowsKey = @"AlternatingRows";
static NSString *RTLKey = @"rtl";
static NSString *ShowWordCount = @"ShowWordCount";
static NSString *markupPreviewMode = @"markupPreviewMode";
static NSString *UseAutoPairing = @"UseAutoPairing";
//static NSString *PasteClipboardOnNewNoteKey = @"PasteClipboardOnNewNote";

//these 4 strings manually localized
NSString *NoteTitleColumnString = @"Title";
NSString *NoteLabelsColumnString = @"Tags";
NSString *NoteDateModifiedColumnString = @"Date Modified";
NSString *NoteDateCreatedColumnString = @"Date Added";

//virtual column
NSString *NotePreviewString = @"Note Preview";

NSString *NVPTFPboardType = @"Notational Velocity Poor Text Format";

NSString *HotKeyAppToFrontName = @"bring Notational Velocity to the foreground";


@implementation GlobalPrefs

static void sendCallbacksForGlobalPrefs(GlobalPrefs* self, SEL selector, id originalSender) {
	
	if (originalSender != self) {
		self->runCallbacksIMP(self, @selector(notifyCallbacksForSelector:excludingSender:), 
							 selector, originalSender);
	}
}

- (id)init {
	if ([super init]) {
	
		runCallbacksIMP = [self methodForSelector:@selector(notifyCallbacksForSelector:excludingSender:)];
		selectorObservers = [[NSMutableDictionary alloc] init];
		
		defaults = [NSUserDefaults standardUserDefaults];
		
		tableColumns = nil;
		
		[defaults registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
			[NSNumber numberWithBool:YES], AutoSuggestLinksKey,
			[NSNumber numberWithBool:YES], AutoFormatsDoneTagKey, 
			[NSNumber numberWithBool:YES], AutoIndentsNewLinesKey, 
			[NSNumber numberWithBool:YES], AutoFormatsListBulletsKey,
			[NSNumber numberWithBool:NO], UseSoftTabsKey,
			[NSNumber numberWithInt:4], NumberOfSpacesInTabKey,
			[NSNumber numberWithBool:YES], PastePreservesStyleKey,
			[NSNumber numberWithBool:YES], TabKeyIndentsKey,
			[NSNumber numberWithBool:YES], ConfirmNoteDeletionKey,
			[NSNumber numberWithBool:YES], CheckSpellingInNoteBodyKey, 
			[NSNumber numberWithBool:NO], TextReplacementInNoteBodyKey, 
			[NSNumber numberWithBool:YES], AutoCompleteSearchesKey, 
			[NSNumber numberWithBool:YES], QuitWhenClosingMainWindowKey, 
			[NSNumber numberWithBool:NO], TriedToImportBlorKey,
			[NSNumber numberWithBool:NO], HorizontalLayoutKey,
			[NSNumber numberWithBool:YES], MakeURLsClickableKey,
			[NSNumber numberWithBool:YES], HighlightSearchTermsKey, 
			[NSNumber numberWithBool:YES], TableColumnsHaveBodyPreviewKey, 
			[NSNumber numberWithDouble:0.0], LastScrollOffsetKey,
			@"General", LastSelectedPreferencesPaneKey, 
			[NSNumber numberWithBool:NO], StatusBarItem, 
			[NSNumber numberWithBool:NO], KeepsMaxTextWidth,
			[NSNumber numberWithInt:600], NoteBodyMaxWidth,
			[NSNumber numberWithInt:2], ColorScheme,
			@"Hide Dock Icon",HideDockIcon,
			[NSNumber numberWithBool:NO], RTLKey,
            [NSNumber numberWithBool:YES], ShowWordCount,
            [NSNumber numberWithInt:MultiMarkdownPreview], markupPreviewMode,
			[NSNumber numberWithBool:NO], UseMarkdownImportKey,
			[NSNumber numberWithBool:NO], UseReadabilityKey,
            [NSNumber numberWithBool:YES], ShowGridKey,
            [NSNumber numberWithBool:NO], AlternatingRowsKey,
            [NSNumber numberWithBool:NO], UseAutoPairing,
			
			[NSArchiver archivedDataWithRootObject:
			 [NSFont fontWithName:@"Helvetica" size:12.0f]], NoteBodyFontKey,
			
			[NSArchiver archivedDataWithRootObject:[NSColor blackColor]], ForegroundTextColorKey,
			[NSArchiver archivedDataWithRootObject:[NSColor whiteColor]], BackgroundTextColorKey,
			
			[NSArchiver archivedDataWithRootObject:
			 [NSColor colorWithCalibratedRed:0.945 green:0.702 blue:0.702 alpha:1.0f]], SearchTermHighlightColorKey,
			
			[NSNumber numberWithFloat:[NSFont smallSystemFontSize]], TableFontSizeKey, 
			[NSArray arrayWithObjects:NoteTitleColumnString, NoteDateModifiedColumnString, nil], NoteAttributesVisibleKey,
			NoteDateModifiedColumnString, TableSortColumnKey,
			[NSNumber numberWithBool:YES], TableIsReverseSortedKey, nil]];
		
		autoCompleteSearches = [defaults boolForKey:AutoCompleteSearchesKey];
	}
	return self;
}

+ (GlobalPrefs *)defaultPrefs {
	static GlobalPrefs *prefs = nil;
	if (!prefs)
		prefs = [[GlobalPrefs alloc] init];
	return prefs;
}

- (void)dealloc {
	
	[tableColumns release];
	[super dealloc];
}

- (void)registerWithTarget:(id)sender forChangesInSettings:(SEL)firstSEL, ... {
	NSAssert(firstSEL != NULL, @"need at least one selector");

	if ([sender respondsToSelector:(@selector(settingChangedForSelectorString:))]) {
	
		va_list argList;
		va_start(argList, firstSEL);
		SEL aSEL = firstSEL;
		do {
			NSString *selectorKey = NSStringFromSelector(aSEL);
			
			NSMutableArray *senders = [selectorObservers objectForKey:selectorKey];
			if (!senders) {
				senders = [[NSMutableArray alloc] initWithCapacity:1];
				[selectorObservers setObject:senders forKey:selectorKey];
			}
			[senders addObject:sender];
		} while (( aSEL = va_arg( argList, SEL) ) != nil);
		va_end(argList);
		
	} else {
		NSLog(@"%s: target %@ does not respond to callback selector!", _cmd, [sender description]);
	}
}

- (void)registerForSettingChange:(SEL)selector withTarget:(id)sender {
	[self registerWithTarget:sender forChangesInSettings:selector, nil];
}

- (void)unregisterForNotificationsFromSelector:(SEL)selector sender:(id)sender {
	NSString *selectorKey = NSStringFromSelector(selector);
	
	NSMutableArray *senders = [selectorObservers objectForKey:selectorKey];
	if (senders) {
		[senders removeObjectIdenticalTo:sender];
		
		if (![senders count])
			[selectorObservers removeObjectForKey:selectorKey];
	} else {
		NSLog(@"Selector %@ has no observers?", NSStringFromSelector(selector));
	}
}

- (void)notifyCallbacksForSelector:(SEL)selector excludingSender:(id)sender {
	NSArray *observers = nil;
	id observer = nil;
	
	NSString *selectorKey = NSStringFromSelector(selector);
	
	if ((observers = [selectorObservers objectForKey:selectorKey])) {
		unsigned int i;
		
		for (i=0; i<[observers count]; i++) {
			
			if ((observer = [observers objectAtIndex:i]) != sender && observer)
				[observer performSelector:@selector(settingChangedForSelectorString:) withObject:selectorKey];
		}
	}
}

- (void)setNotationPrefs:(NotationPrefs*)newNotationPrefs sender:(id)sender {
	[notationPrefs autorelease];
	notationPrefs = [newNotationPrefs retain];
	
	[self resolveNoteBodyFontFromNotationPrefsFromSender:sender];
	
	SEND_CALLBACKS();
}

- (NotationPrefs*)notationPrefs {
	return notationPrefs;
}

- (BOOL)autoCompleteSearches {
	return autoCompleteSearches;
}

- (void)setAutoCompleteSearches:(BOOL)value sender:(id)sender {
	autoCompleteSearches = value;
	[defaults setBool:value forKey:AutoCompleteSearchesKey];
	
	SEND_CALLBACKS();
}

- (void)setTabIndenting:(BOOL)value sender:(id)sender {
    [defaults setBool:value forKey:TabKeyIndentsKey];
    
    SEND_CALLBACKS();
}
- (BOOL)tabKeyIndents {
    return [defaults boolForKey:TabKeyIndentsKey];
}

- (void)setUseTextReplacement:(BOOL)value sender:(id)sender {
    [defaults setBool:value forKey:TextReplacementInNoteBodyKey];
    
    SEND_CALLBACKS();
}

- (BOOL)useTextReplacement {
    return [defaults boolForKey:TextReplacementInNoteBodyKey];
}

- (void)setCheckSpellingAsYouType:(BOOL)value sender:(id)sender {
    [defaults setBool:value forKey:CheckSpellingInNoteBodyKey];
    
    SEND_CALLBACKS();
}

- (BOOL)checkSpellingAsYouType {
    return [defaults boolForKey:CheckSpellingInNoteBodyKey];
}

- (void)setConfirmNoteDeletion:(BOOL)value sender:(id)sender {
    [defaults setBool:value forKey:ConfirmNoteDeletionKey];
    
    SEND_CALLBACKS();
}
- (BOOL)confirmNoteDeletion {
    return [defaults boolForKey:ConfirmNoteDeletionKey];
}

- (void)setQuitWhenClosingWindow:(BOOL)value sender:(id)sender {
    [defaults setBool:value forKey:QuitWhenClosingMainWindowKey];
    
    SEND_CALLBACKS();
}
- (BOOL)quitWhenClosingWindow {
    return [defaults boolForKey:QuitWhenClosingMainWindowKey];
}

- (void)setAppActivationKeyCombo:(PTKeyCombo*)aCombo sender:(id)sender {
	if (aCombo) {
		[appActivationKeyCombo release];
		appActivationKeyCombo = [aCombo retain];
		
		[[self appActivationHotKey] setKeyCombo:appActivationKeyCombo];
	
		[defaults setInteger:[aCombo keyCode] forKey:AppActivationKeyCodeKey];
		[defaults setInteger:[aCombo modifiers] forKey:AppActivationModifiersKey];
		
		SEND_CALLBACKS();
	}
}

- (PTHotKey*)appActivationHotKey {
	if (!appActivationHotKey) {
		appActivationHotKey = [[PTHotKey alloc] init];
		[appActivationHotKey setName:HotKeyAppToFrontName];
		[appActivationHotKey setKeyCombo:[self appActivationKeyCombo]];
	}
	
	return appActivationHotKey;
}

- (PTKeyCombo*)appActivationKeyCombo {
	if (!appActivationKeyCombo) {
		appActivationKeyCombo = [[PTKeyCombo alloc] initWithKeyCode:[[defaults objectForKey:AppActivationKeyCodeKey] intValue]
														  modifiers:[[defaults objectForKey:AppActivationModifiersKey] intValue]];
	}
	return appActivationKeyCombo;
}

- (BOOL)registerAppActivationKeystrokeWithTarget:(id)target selector:(SEL)selector {
	PTHotKey *hotKey = [self appActivationHotKey];
	
	[hotKey setTarget:target];
	[hotKey setAction:selector];
	
	[[PTHotKeyCenter sharedCenter] unregisterHotKeyForName:HotKeyAppToFrontName];
	
	return [[PTHotKeyCenter sharedCenter] registerHotKey:hotKey];
}

- (void)setPastePreservesStyle:(BOOL)value sender:(id)sender {
    [defaults setBool:value forKey:PastePreservesStyleKey];
    
	SEND_CALLBACKS();
}

- (BOOL)pastePreservesStyle {
    
    return [defaults boolForKey:PastePreservesStyleKey];
}

- (void)setAutoFormatsDoneTag:(BOOL)value sender:(id)sender {
    [defaults setBool:value forKey:AutoFormatsDoneTagKey];
	
	SEND_CALLBACKS();
}
- (BOOL)autoFormatsDoneTag {
	return [defaults boolForKey:AutoFormatsDoneTagKey];
}
- (BOOL)autoFormatsListBullets {
	return [defaults boolForKey:AutoFormatsListBulletsKey];
}
- (void)setAutoFormatsListBullets:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:AutoFormatsListBulletsKey];
	
	SEND_CALLBACKS();
}

- (BOOL)autoIndentsNewLines {
	return [defaults boolForKey:AutoIndentsNewLinesKey];
}
- (void)setAutoIndentsNewLines:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:AutoIndentsNewLinesKey];
	
	SEND_CALLBACKS();
}

- (void)setLinksAutoSuggested:(BOOL)value sender:(id)sender {
    [defaults setBool:value forKey:AutoSuggestLinksKey];
	
	SEND_CALLBACKS();
}
- (BOOL)linksAutoSuggested {
    return [defaults boolForKey:AutoSuggestLinksKey];
}

- (void)setMakeURLsClickable:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:MakeURLsClickableKey];
	
	SEND_CALLBACKS();
}
- (BOOL)URLsAreClickable {
	return [defaults boolForKey:MakeURLsClickableKey];
}

- (void)setRTL:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:RTLKey];
	
	SEND_CALLBACKS();
}
- (BOOL)rtl {
	return [defaults boolForKey:RTLKey];
}

- (BOOL)showWordCount{
	return [defaults boolForKey:ShowWordCount];
}

- (void)setShowWordCount:(BOOL)value{
	[defaults setBool:value forKey:ShowWordCount];
}

- (void)setUseMarkdownImport:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:UseMarkdownImportKey];
	
	SEND_CALLBACKS();
}
- (BOOL)useMarkdownImport {
	return [defaults boolForKey:UseMarkdownImportKey];
}
- (void)setUseReadability:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:UseReadabilityKey];
	
	SEND_CALLBACKS();
}
- (BOOL)useReadability {
	return [defaults boolForKey:UseReadabilityKey];
}

- (void)setShowGrid:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:ShowGridKey];
	
	SEND_CALLBACKS();
}
- (BOOL)showGrid {
	return [defaults boolForKey:ShowGridKey];
}
- (void)setAlternatingRows:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:AlternatingRowsKey];
	
	SEND_CALLBACKS();
}
- (BOOL)alternatingRows {
	return [defaults boolForKey:AlternatingRowsKey];
}

- (void)setUseAutoPairing:(BOOL)value{
    [defaults setBool:value forKey:UseAutoPairing];
}

- (BOOL)useAutoPairing{
	return [defaults boolForKey:UseAutoPairing];
}

- (void)setShouldHighlightSearchTerms:(BOOL)shouldHighlight sender:(id)sender {
	[defaults setBool:shouldHighlight forKey:HighlightSearchTermsKey];
	
	SEND_CALLBACKS();
}
- (BOOL)highlightSearchTerms {
	return [defaults boolForKey:HighlightSearchTermsKey];
}

- (void)setSearchTermHighlightColor:(NSColor*)color sender:(id)sender {
	if (color) {
		
		[searchTermHighlightAttributes release];
		searchTermHighlightAttributes = nil;
		
		[defaults setObject:[NSArchiver archivedDataWithRootObject:color] forKey:SearchTermHighlightColorKey];
		
		SEND_CALLBACKS();
	}
}

- (NSColor*)searchTermHighlightColorRaw:(BOOL)isRaw {
	
	NSData *theData = [defaults dataForKey:SearchTermHighlightColorKey];
	if (theData) {
		NSColor *color = (NSColor *)[NSUnarchiver unarchiveObjectWithData:theData];
		if (isRaw) return color;
		if (color) {
			//nslayoutmanager temporary attributes don't seem to like alpha components, so synthesize translucency using the bg color
			NSColor *fauxAlphaSTHC = [[color colorUsingColorSpaceName:NSCalibratedRGBColorSpace] colorWithAlphaComponent:1.0];
			return [fauxAlphaSTHC blendedColorWithFraction:(1.0 - [color alphaComponent]) ofColor:[self backgroundTextColor]];
		}
	}

	return nil;
}

- (NSDictionary*)searchTermHighlightAttributes {
	NSColor *highlightColor = nil;
	
	if (!searchTermHighlightAttributes && (highlightColor = [self searchTermHighlightColorRaw:NO])) {
		searchTermHighlightAttributes = [[NSDictionary dictionaryWithObjectsAndKeys:highlightColor, NSBackgroundColorAttributeName, nil] retain];
	}
	return searchTermHighlightAttributes;
	
}

- (void)setSoftTabs:(BOOL)value sender:(id)sender {
	[defaults setBool:value forKey:UseSoftTabsKey];
	
	SEND_CALLBACKS();
}

- (BOOL)softTabs {
	return [defaults boolForKey:UseSoftTabsKey];
}

- (int)numberOfSpacesInTab {
	return [defaults integerForKey:NumberOfSpacesInTabKey];
}

BOOL ColorsEqualWith8BitChannels(NSColor *c1, NSColor *c2) {
	//sometimes floating point numbers really don't like to be compared to each other

	CGFloat pRed, pGreen, pBlue, gRed, gGreen, gBlue, pAlpha, gAlpha;
	[[c1 colorUsingColorSpaceName:NSCalibratedRGBColorSpace] getRed:&pRed green:&pGreen blue:&pBlue alpha:&pAlpha];
	[[c2 colorUsingColorSpaceName:NSCalibratedRGBColorSpace] getRed:&gRed green:&gGreen blue:&gBlue alpha:&gAlpha];
	
#define SCR(__ch) ((int)roundf(((__ch) * 255.0)))
	
	return (SCR(pRed) == SCR(gRed) && SCR(pBlue) == SCR(gBlue) && SCR(pGreen) == SCR(gGreen) && SCR(pAlpha) == SCR(gAlpha));
}

- (void)resolveNoteBodyFontFromNotationPrefsFromSender:(id)sender {
	
	NSFont *prefsFont = [notationPrefs baseBodyFont];
	if (prefsFont) {
		NSFont *noteFont = [self noteBodyFont];
		
		if (![[prefsFont fontName] isEqualToString:[noteFont fontName]] || 
			[prefsFont pointSize] != [noteFont pointSize]) {
			
			NSLog(@"archived notationPrefs base font does not match current global default font!");
			[self _setNoteBodyFont:prefsFont];
			
			SEND_CALLBACKS();
		}
	}
}

- (void)_setNoteBodyFont:(NSFont*)aFont {
	NSFont *oldFont = noteBodyFont;
	noteBodyFont = [aFont retain];
	
	[noteBodyParagraphStyle release];
	noteBodyParagraphStyle = nil;
	
	[noteBodyAttributes release];
	noteBodyAttributes = nil; //cause method to re-update
	
	[defaults setObject:[NSArchiver archivedDataWithRootObject:noteBodyFont] forKey:NoteBodyFontKey]; 
	
	//restyle any PTF data on the clipboard to the new font
	NSData *ptfData = [[NSPasteboard generalPasteboard] dataForType:NVPTFPboardType];
	NSMutableAttributedString *newString = [[[NSMutableAttributedString alloc] initWithRTF:ptfData documentAttributes:nil] autorelease];
	
	[newString restyleTextToFont:noteBodyFont usingBaseFont:oldFont];
	
	if ((ptfData = [newString RTFFromRange:NSMakeRange(0, [newString length]) documentAttributes:nil])) {
		[[NSPasteboard generalPasteboard] setData:ptfData forType:NVPTFPboardType];
	}
	[oldFont release];
}

- (void)setNoteBodyFont:(NSFont*)aFont sender:(id)sender {
	
	if (aFont) {
		[self _setNoteBodyFont:aFont];
		
		SEND_CALLBACKS();
	}
}

- (NSFont*)noteBodyFont {
	BOOL triedOnce = NO;
	
	if (!noteBodyFont) {
		retry:
		@try {
			noteBodyFont = [[NSUnarchiver unarchiveObjectWithData:[defaults objectForKey:NoteBodyFontKey]] retain];
		} @catch (NSException *e) {
			NSLog(@"Error trying to unarchive default note body font (%@, %@)", [e name], [e reason]);
		}
		
		if ((!noteBodyFont || ![noteBodyFont isKindOfClass:[NSFont class]]) && !triedOnce) {
			triedOnce = YES;
			[defaults removeObjectForKey:NoteBodyFontKey];
			goto retry;
		}
	}
	
    return noteBodyFont;
}

- (NSDictionary*)noteBodyAttributes {
	NSFont *bodyFont = [self noteBodyFont];
	if (!noteBodyAttributes && bodyFont) {
		//NSLog(@"notebody att2");
		
		NSMutableDictionary *attrs = [[NSMutableDictionary dictionaryWithObjectsAndKeys:bodyFont, NSFontAttributeName, nil] retain];
		
		//not storing the foreground color in each note will make the database smaller, and black is assumed when drawing text
		//NSColor *fgColor = [self foregroundTextColor];
		NSColor *fgColor = [[NSApp delegate] foregrndColor];
		
		if (!ColorsEqualWith8BitChannels([NSColor blackColor], fgColor)) {
		//	NSLog(@"golly1");
			[attrs setObject:fgColor forKey:NSForegroundColorAttributeName];
		}
		// background text color is handled directly by the NSTextView subclass and so does not need to be stored here
		if ([self _bodyFontIsMonospace]) {
			
		//	NSLog(@"notebody att3");
			NSParagraphStyle *pStyle = [self noteBodyParagraphStyle];
			if (pStyle)
				[attrs setObject:pStyle forKey:NSParagraphStyleAttributeName];
		}
	   /*NSTextWritingDirectionEmbedding*/
		//[NSArray arrayWithObjects:[NSNumber numberWithInt:0], [NSNumber numberWithInt:0], nil], @"NSWritingDirection", //for auto-LTR-RTL text
		noteBodyAttributes = attrs;
	}else {
		//NSLog(@"notebody att4");
		NSMutableDictionary *attrs = [[NSMutableDictionary dictionaryWithObjectsAndKeys:bodyFont, NSFontAttributeName, nil] retain];
		NSColor *fgColor = [[NSApp delegate] foregrndColor];
		
		//	if (!ColorsEqualWith8BitChannels([NSColor blackColor], fgColor)) {
		//NSLog(@"golly122");
		[attrs setObject:fgColor forKey:NSForegroundColorAttributeName];
		noteBodyAttributes = attrs;
		//	}
	}

	return noteBodyAttributes;
}

- (BOOL)_bodyFontIsMonospace {
	NSString *name = [noteBodyFont fontName];
	return (([noteBodyFont isFixedPitch] || [name caseInsensitiveCompare:@"Osaka-Mono"] == NSOrderedSame) && 
			[name caseInsensitiveCompare:@"MS-PGothic"] != NSOrderedSame);
}

- (NSParagraphStyle*)noteBodyParagraphStyle {
	NSFont *bodyFont = [self noteBodyFont];

	if (!noteBodyParagraphStyle && bodyFont) {
		int numberOfSpaces = [self numberOfSpacesInTab];
		NSMutableString *sizeString = [[NSMutableString alloc] initWithCapacity:numberOfSpaces];
		while (numberOfSpaces--) {
			[sizeString appendString:@" "];
		}
		NSDictionary *sizeAttribute = [[NSDictionary alloc] initWithObjectsAndKeys:bodyFont, NSFontAttributeName, nil];
		float sizeOfTab = [sizeString sizeWithAttributes:sizeAttribute].width;
		[sizeAttribute release];
		[sizeString release];
		
		noteBodyParagraphStyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
		
		NSTextTab *textTabToBeRemoved;
		NSEnumerator *enumerator = [[noteBodyParagraphStyle tabStops] objectEnumerator];
		while ((textTabToBeRemoved = [enumerator nextObject])) {
			[noteBodyParagraphStyle removeTabStop:textTabToBeRemoved];
		}
		//[paragraphStyle setHeadIndent:sizeOfTab]; //for soft-indents, this would probably have to be applied contextually, and heaven help us for soft tabs

		[noteBodyParagraphStyle setDefaultTabInterval:sizeOfTab];
	}
	
	return noteBodyParagraphStyle;
}

- (void)setForegroundTextColor:(NSColor*)aColor sender:(id)sender {
	if (aColor) {
		[noteBodyAttributes release];
		noteBodyAttributes = nil;
		
		[defaults setObject:[NSArchiver archivedDataWithRootObject:aColor] forKey:ForegroundTextColorKey];
		
		SEND_CALLBACKS();
	}	
}

- (NSColor*)foregroundTextColor {
	NSData *theData = [defaults dataForKey:ForegroundTextColorKey];
	if (theData) return (NSColor *)[NSUnarchiver unarchiveObjectWithData:theData];
	return nil;
}

- (void)setBackgroundTextColor:(NSColor*)aColor sender:(id)sender {
	
	if (aColor) {
		//highlight color is based on blended-alpha version of background color
		//(because nslayoutmanager temporary attributes don't seem to like alpha components)
		//so it's necessary to invalidate the effective cache of that computed highlight color
		[searchTermHighlightAttributes release];
		searchTermHighlightAttributes = nil;

		[defaults setObject:[NSArchiver archivedDataWithRootObject:aColor] forKey:BackgroundTextColorKey];
	
		SEND_CALLBACKS();
	}
}

- (NSColor*)backgroundTextColor {
	//don't need to cache the unarchived color, as it's not used in a random-access pattern
	
	NSData *theData = [defaults dataForKey:BackgroundTextColorKey];
	if (theData) return (NSColor *)[NSUnarchiver unarchiveObjectWithData:theData];

	return nil;	
}

- (BOOL)tableColumnsShowPreview {
	return [defaults boolForKey:TableColumnsHaveBodyPreviewKey];
}

- (void)setTableColumnsShowPreview:(BOOL)showPreview sender:(id)sender {
	[defaults setBool:showPreview forKey:TableColumnsHaveBodyPreviewKey];
	
	SEND_CALLBACKS();
}

- (float)tableFontSize {
	return [defaults floatForKey:TableFontSizeKey];
}

- (void)setTableFontSize:(float)fontSize sender:(id)sender {
	[defaults setFloat:fontSize forKey:TableFontSizeKey];
	
	SEND_CALLBACKS();
}

- (void)removeTableColumn:(NSString*)columnKey sender:(id)sender {
	[tableColumns removeObject:columnKey];
	tableColsBitmap = 0U;
	
	[defaults setObject:tableColumns forKey:NoteAttributesVisibleKey];
	
	SEND_CALLBACKS();
}
- (void)addTableColumn:(NSString*)columnKey sender:(id)sender {
	if (![tableColumns containsObject:columnKey]) {
		[tableColumns addObject:columnKey];
		tableColsBitmap = 0U;
		
		[defaults setObject:tableColumns forKey:NoteAttributesVisibleKey];
		
		SEND_CALLBACKS();
	}
}

- (NSArray*)visibleTableColumns {
	if (!tableColumns) {
		tableColumns = [[NSMutableArray arrayWithArray:[defaults arrayForKey:NoteAttributesVisibleKey]] retain];
		tableColsBitmap = 0U;
	}
	
	if (![tableColumns count])
		[self addTableColumn:NoteTitleColumnString sender:self];
		
	return tableColumns;
}


- (unsigned int)tableColumnsBitmap {
	if (tableColsBitmap == 0U) {
		if ([tableColumns containsObject:NoteTitleColumnString])
			tableColsBitmap = (tableColsBitmap | (1 << NoteTitleColumn));
		if ([tableColumns containsObject:NoteLabelsColumnString])
			tableColsBitmap = (tableColsBitmap | (1 << NoteLabelsColumn));
		if ([tableColumns containsObject:NoteDateModifiedColumnString])
			tableColsBitmap = (tableColsBitmap | (1 << NoteDateModifiedColumn));
		if ([tableColumns containsObject:NoteDateCreatedColumnString])
			tableColsBitmap = (tableColsBitmap | (1 << NoteDateCreatedColumn));		
	}
	return tableColsBitmap;
}

- (void)setSortedTableColumnKey:(NSString*)sortedKey reversed:(BOOL)reversed sender:(id)sender {
	[defaults setBool:reversed forKey:TableIsReverseSortedKey];
    [defaults setObject:sortedKey forKey:TableSortColumnKey];
    
    SEND_CALLBACKS();
}

- (NSString*)sortedTableColumnKey {
    return [defaults objectForKey:TableSortColumnKey];
}

- (BOOL)tableIsReverseSorted {
    return [defaults boolForKey:TableIsReverseSortedKey];
}

- (void)setHorizontalLayout:(BOOL)value sender:(id)sender {
	if ([self horizontalLayout] != value) {
		[defaults setBool:value forKey:HorizontalLayoutKey];
		
		SEND_CALLBACKS();
	}
}
- (BOOL)horizontalLayout {
	return [defaults boolForKey:HorizontalLayoutKey];
}

- (NSString*)lastSelectedPreferencesPane {
	return [defaults stringForKey:LastSelectedPreferencesPaneKey];
}
- (void)setLastSelectedPreferencesPane:(NSString*)pane sender:(id)sender {
	[defaults setObject:pane forKey:LastSelectedPreferencesPaneKey];
	
	SEND_CALLBACKS();
}

- (void)setLastSearchString:(NSString*)string selectedNote:(id<SynchronizedNote>)aNote scrollOffsetForTableView:(NotesTableView*)tv sender:(id)sender {
	
	NSMutableString *stringMinusBreak = [[string mutableCopy] autorelease];
	[stringMinusBreak replaceOccurrencesOfString:@"\n" withString:@" " options:NSLiteralSearch range:NSMakeRange(0, [stringMinusBreak length])];
	
	[defaults setObject:stringMinusBreak forKey:LastSearchStringKey];
	
	CFUUIDBytes *bytes = [aNote uniqueNoteIDBytes];
	NSString *uuidString = nil;
	if (bytes) uuidString = [NSString uuidStringWithBytes:*bytes];

	[defaults setObject:uuidString forKey:LastSelectedNoteUUIDBytesKey];
	
	double offset = [tv distanceFromRow:[(FastListDataSource*)[tv dataSource] indexOfObjectIdenticalTo:aNote] forVisibleArea:[tv visibleRect]];
	[defaults setDouble:offset forKey:LastScrollOffsetKey];
	
	SEND_CALLBACKS();
}

- (NSString*)lastSearchString {
	return [defaults objectForKey:LastSearchStringKey];
}

- (CFUUIDBytes)UUIDBytesOfLastSelectedNote {
	CFUUIDBytes bytes = {0};
	
	NSString *uuidString = [defaults objectForKey:LastSelectedNoteUUIDBytesKey];
	if (uuidString) bytes = [uuidString uuidBytes];

	return bytes;
}

- (double)scrollOffsetOfLastSelectedNote {
	return [defaults doubleForKey:LastScrollOffsetKey];
}

- (void)saveCurrentBookmarksFromSender:(id)sender {
	//run this during quit and when saved searches change?
	NSArray *bookmarks = [bookmarksController dictionaryReps];
	if (bookmarks) {
		[defaults setObject:bookmarks forKey:BookmarksKey];
		[defaults setBool:[bookmarksController isVisible] forKey:@"BookmarksVisible"];
	}
		
	SEND_CALLBACKS();
}

- (BookmarksController*)bookmarksController {
	if (!bookmarksController) {
		bookmarksController = [[BookmarksController alloc] initWithBookmarks:[defaults arrayForKey:BookmarksKey]];
	}
	return bookmarksController;
}

- (void)setAliasDataForDefaultDirectory:(NSData*)alias sender:(id)sender {
    [defaults setObject:alias forKey:DirectoryAliasKey];
	
    SEND_CALLBACKS();
}

- (NSData*)aliasDataForDefaultDirectory {
    return [defaults dataForKey:DirectoryAliasKey];
}

- (NSString*)displayNameForDefaultDirectoryWithFSRef:(FSRef*)fsRef {

    if (!fsRef)
	return nil;
    
    if (IsZeros(fsRef, sizeof(FSRef))) {
	if (![[self aliasDataForDefaultDirectory] fsRefAsAlias:fsRef])
	    return nil;
    }
    CFStringRef displayName = NULL;
    if (LSCopyDisplayNameForRef(fsRef, &displayName) == noErr) {
	return [(NSString*)displayName autorelease];
    }
    return nil;
}

- (NSString*)humanViewablePathForDefaultDirectory {
    //resolve alias to fsref
    FSRef targetRef;
    if ([[self aliasDataForDefaultDirectory] fsRefAsAlias:&targetRef]) {	    
	//follow the parent fsrefs up the tree, calling LSCopyDisplayNameForRef, hoping that the root is a drive name
	
	NSMutableArray *directoryNames = [NSMutableArray arrayWithCapacity:4];
	FSRef parentRef, *currentRef = &targetRef;
	
	OSStatus err = noErr;
	
	do {
	    
	    if ((err = FSGetCatalogInfo(currentRef, kFSCatInfoNone, NULL, NULL, NULL, &parentRef)) == noErr) {
		
		CFStringRef displayName = NULL;
		if ((err = LSCopyDisplayNameForRef(currentRef, &displayName)) == noErr) {
		    
		    if (displayName) {
			[directoryNames insertObject:(id)displayName atIndex:0];
			CFRelease(displayName);
		    }
		}
		
		currentRef = &parentRef;
	    }
	} while (err == noErr);
	
	//build new string delimited by triangles like pages in its recent items menu
	return [directoryNames componentsJoinedByString:@" : "];
	
    }
    
    return nil;
}

- (void)setBlorImportAttempted:(BOOL)value {
	[defaults setBool:value forKey:TriedToImportBlorKey];
}

- (BOOL)triedToImportBlor {
	return [defaults boolForKey:TriedToImportBlorKey];
}
- (void)synchronize {
    [defaults synchronize];
}

- (NSImage*)iconForDefaultDirectoryWithFSRef:(FSRef*)fsRef {
  OSStatus err = noErr;
  
  if (!fsRef)
    return nil;
  
  if (IsZeros(fsRef, sizeof(FSRef))) {
    if (![[self aliasDataForDefaultDirectory] fsRefAsAlias:fsRef])
	    return nil;
  }
  IconRef iconRef;
  if ((err = GetIconRefFromFileInfo(fsRef, 0, NULL, 0, NULL, kIconServicesNormalUsageFlag, &iconRef, NULL)) == noErr) {
    
    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(16.0f, 16.0f)] autorelease];
    NSRect frame = NSMakeRect(0.0f,0.0f,16.0f,16.0f);
    
    [image lockFocus];
    err = PlotIconRefInContext([[NSGraphicsContext currentContext] graphicsPort], (CGRect *)&frame, 0, 0, nil, 0, iconRef);
    [image unlockFocus];
    
    if (err == noErr)
	    return image;
  }
  
  NSLog(@"iconForDefaultDirectory error: %d", err);
  
  return nil;
}

//elasticthreads' work

- (BOOL)managesTextWidthInWindow{
	return [defaults boolForKey:KeepsMaxTextWidth];
}

- (int)maxNoteBodyWidth{	
	return [defaults integerForKey:NoteBodyMaxWidth];
}

- (void)setMaxNoteBodyWidth:(int)maxWidth{
	[defaults setInteger:maxWidth forKey:NoteBodyMaxWidth];
	[defaults synchronize];
}

@end
