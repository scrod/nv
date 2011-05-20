//
//  PreviewController.h
//  Notation
//
//  Created by Christian Tietze on 15.10.10.
//  Copyright 2010

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import "MAAttachedWindow.h"

@class AppController;
@class NoteObject;
@class ETTransparentButton;

@interface PreviewController : NSWindowController 
{
  IBOutlet WebView *preview;
	IBOutlet NSTextView *sourceView;
	IBOutlet NSTabView *tabView;
	IBOutlet NSButton *tabSwitcher;
	IBOutlet NSButton *shareButton;
  IBOutlet NSButton *saveButton;
  IBOutlet NSButton *stickyPreviewButton;
  IBOutlet NSButton *printPreviewButton;
	ETTransparentButton *viewOnWebButton;
  BOOL isPreviewOutdated;
  BOOL isPreviewSticky;
	NSMutableData *receivedData;
//    IBOutlet NSWindow *wnd;
	MAAttachedWindow *attachedWindow;
	MAAttachedWindow *confirmWindow;
	IBOutlet NSTextField *urlTextField;
	IBOutlet NSView *shareNotification;
	IBOutlet NSView *shareConfirmation;
	ETTransparentButton *shareCancel;
  ETTransparentButton *shareConfirm;
	NSString *shareURL;
	NSString *cssString;
	NSString *htmlString;

	IBOutlet NSButton *includeTemplate;
  IBOutlet NSTextField *templateNote;
	IBOutlet NSView *accessoryView;
	
	NoteObject *lastNote;
}

@property (assign) BOOL isPreviewOutdated;
@property (retain) WebView *preview;
@property (assign) BOOL isPreviewSticky;

-(IBAction)saveHTML:(id)sender;
-(IBAction)switchTabs:(id)sender;
-(IBAction)shareNote:(id)sender;
-(IBAction)shareAsk:(id)sender;
-(IBAction)cancelShare:(id)sender;

-(IBAction)makePreviewSticky:(id)sender;
-(IBAction)makePreviewNotSticky:(id)sender;
-(IBAction)printPreview:(id)sender;
-(BOOL)previewIsVisible;
-(void)togglePreview:(id)sender;
-(void)requestPreviewUpdate:(NSNotification *)notification;
+(void)createCustomFiles;
-(SEL)markupProcessorSelector:(NSInteger)previewMode;
-(NSString *)urlEncodeValue:(NSString *)str;
-(void)showShareURL:(NSString *)url isError:(BOOL)isError;
-(IBAction)hideShareURL:(id)sender;
-(void)closeShareURLView;
-(IBAction)openShareURL:(id)sender;
+(NSString *)css;
+(NSString *)html;
@end
