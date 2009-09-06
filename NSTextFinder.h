/*
 *  NSTextFinder.h
 *  Notation
 *
 *  Created by class-dump (Steve Nygard) from AppKit framework in 10.4
 *
 */

#import <Cocoa/Cocoa.h>

enum {LAST_FIND_UNKNOWN, LAST_FIND_NO, LAST_FIND_YES};

@interface NSTextFinder : NSObject
{
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
- (int)lastFindWasSuccessful;
@end

