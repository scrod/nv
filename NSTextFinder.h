/*
 *  NSTextFinder.h
 *  Notation
 *
 *  Created by class-dump (Steve Nygard) from AppKit framework in 10.4
 *
 */

enum {LAST_FIND_UNKNOWN, LAST_FIND_NO, LAST_FIND_YES};
//#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_7
#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_7
//#if NSFoundationVersionNumber < NSFoundationVersionNumber10_7
#import <Cocoa/Cocoa.h>


@interface NSTextFinder : NSObject
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
    //10.6
    NSComboBox *findComboBox;
    NSComboBox *replaceComboBox;
    NSTextField *statusField;
    NSButton *ignoreCaseButton;
    NSButton *replaceAllButton;
    NSButton *replaceButton;
    NSButton *findNextButton;
    NSButton *findPreviousButton;
    NSButton *replaceAndFindButton;
    NSButton *wrapAroundButton;
    NSPopUpButton *matchPopUp;
    NSTextView *fieldEditor;
    NSString *findString;
    BOOL lastFindWasSuccessful;
    BOOL findStringChangedInUI;
    BOOL findStringNeedsToBeRefreshedFromPB;
    NSInteger lastChangeCount;
    BOOL caseInsensitiveSearchDefault;
    NSInteger substringMatchDefault;
    NSMutableArray *recentFindStrings;
    NSMutableArray *recentFindOptions;
    NSMutableArray *recentReplaceStrings;
    NSInteger numberOfRecentStrings;
#else
    // 10.4
    NSTextField *findTextField;
    NSTextField *replaceTextField;
    NSTextField *statusField;
    NSButton *ignoreCaseButton;
    NSButton *replaceAllButton;
    NSButton *replaceButton;
    NSButton *findNextButton;
    NSButton *findPreviousButton;
    NSButton *replaceAndFindButton;
    NSButton *wrapAroundButton;
    NSPopUpButton *matchPopUp;
    NSTextView *fieldEditor;
    NSString *findString;
@public
    BOOL lastFindWasSuccessful;
    BOOL findStringChangedInUI;
    BOOL findStringNeedsToBeRefreshedFromPB;
#endif
}

+ (id)sharedTextFinder;
- (id)init;
- (void)dealloc;
- (void)finalize;
- (id)windowWillReturnFieldEditor:(id)fp8 toObject:(id)fp12;
- (void)appDidActivate:(id)fp8;
- (BOOL)loadFindStringFromPasteboard;
- (void)loadFindStringToPasteboard;
- (void)loadUI;
- (void)controlTextDidChange:(id)fp8;
- (id)findString;
- (void)setFindString:(id)fp8 writeToPasteboard:(BOOL)fp12 updateUI:(BOOL)fp16;
- (id)textObjectToSearchIn;
- (id)findPanel:(BOOL)fp8;
- (void)takeFindStringFromView:(id)fp8;
- (unsigned int)optionsFromPanel;
- (BOOL)findInView:(id)fp8 forward:(BOOL)fp12;
- (BOOL)replaceInView:(id)fp8;
- (BOOL)replaceAndFindInView:(id)fp8;
- (int)replaceAllInView:(id)fp8 selectionOnly:(BOOL)fp12;
- (BOOL)selectAllInView:(id)fp8 selectionOnly:(BOOL)fp12;
- (void)orderFrontFindPanel:(id)fp8;
- (void)findNextAndOrderFindPanelOut:(id)fp8;
- (void)performFindPanelAction:(id)fp8;
- (void)performFindPanelAction:(int)fp8 forClient:(id)fp12;
- (BOOL)validateFindPanelAction:(int)fp8 forClient:(id)fp12;
- (void)windowDidUpdate:(id)fp8;

@end

@interface NSTextFinder (LastFind)
- (int)nv_lastFindWasSuccessful;
@end


// Dump from 10.6 x86_64
#if 0
@interface NSTextFinder : NSObject <NSWindowDelegate, NSComboBoxDelegate>
{
    NSComboBox *findComboBox;
    NSComboBox *replaceComboBox;
    NSTextField *statusField;
    NSButton *ignoreCaseButton;
    NSButton *replaceAllButton;
    NSButton *replaceButton;
    NSButton *findNextButton;
    NSButton *findPreviousButton;
    NSButton *replaceAndFindButton;
    NSButton *wrapAroundButton;
    NSPopUpButton *matchPopUp;
    NSTextView *fieldEditor;
    NSString *findString;
    BOOL lastFindWasSuccessful;
    BOOL findStringChangedInUI;
    BOOL findStringNeedsToBeRefreshedFromPB;
    long long lastChangeCount;
    BOOL caseInsensitiveSearchDefault;
    long long substringMatchDefault;
    NSMutableArray *recentFindStrings;
    NSMutableArray *recentFindOptions;
    NSMutableArray *recentReplaceStrings;
    long long numberOfRecentStrings;
}

+ (id)sharedTextFinder;
- (id)init;
- (void)awakeFromNib;
- (void)dealloc;
- (id)windowWillReturnFieldEditor:(id)arg1 toObject:(id)arg2;
- (BOOL)needToRefreshFromPasteboard;
- (void)appDidActivate:(id)arg1;
- (BOOL)loadFindStringFromPasteboard;
- (void)loadFindStringToPasteboard;
- (void)restoreDefaultSearchOptions;
- (void)makeCurrentSearchOptionsDefault;
- (void)setDefaultSearchOptions:(id)arg1;
- (void)loadUI;
- (void)controlTextDidChange:(id)arg1;
- (void)addStringToRecentSearchStrings:(id)arg1;
- (void)addStringToRecentReplaceStrings:(id)arg1;
- (id)comboBox:(id)arg1 objectValueForItemAtIndex:(long long)arg2;
- (long long)numberOfItemsInComboBox:(id)arg1;
- (void)comboBoxSelectionDidChange:(id)arg1;
- (id)findString;
- (void)setFindString:(id)arg1 writeToPasteboard:(BOOL)arg2 updateUI:(BOOL)arg3;
- (id)textObjectToSearchIn;
- (id)findPanel:(BOOL)arg1;
- (void)takeFindStringFromView:(id)arg1;
- (unsigned long long)optionsFromPanel;
- (BOOL)findInView:(id)arg1 forward:(BOOL)arg2;
- (BOOL)replaceInView:(id)arg1;
- (BOOL)replaceAndFindInView:(id)arg1;
- (long long)replaceAllInView:(id)arg1 selectionOnly:(BOOL)arg2;
- (BOOL)selectAllInView:(id)arg1 selectionOnly:(BOOL)arg2;
- (void)orderFrontFindPanel:(id)arg1;
- (void)findNextAndOrderFindPanelOut:(id)arg1;
- (void)performFindPanelAction:(id)arg1;
- (void)performFindPanelAction:(unsigned long long)arg1 forClient:(id)arg2;
- (BOOL)validateFindPanelAction:(unsigned long long)arg1 forClient:(id)arg2;
- (void)windowDidUpdate:(id)arg1;

@end
#endif

#endif
