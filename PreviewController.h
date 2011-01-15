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

@interface PreviewController : NSWindowController 
{
    IBOutlet WebView *preview;
	IBOutlet NSTextView *sourceView;
	IBOutlet NSTabView *tabView;
	IBOutlet NSButton *tabSwitcher;
	IBOutlet NSButton *shareButton;
	IBOutlet NSButton *viewOnWebButton;
    BOOL isPreviewOutdated;
	NSMutableData *receivedData;
//    IBOutlet NSWindow *wnd;
	MAAttachedWindow *attachedWindow;
	MAAttachedWindow *confirmWindow;
	IBOutlet NSTextField *urlTextField;
	IBOutlet NSView *shareNotification;
	IBOutlet NSView *shareConfirmation;
	IBOutlet NSButton *shareCancel;
	IBOutlet NSButton *shareConfirm;
	NSString *shareURL;
	NSString *cssString;
	NSString *htmlString;

	IBOutlet NSButton *includeTemplate;
	IBOutlet NSView *accessoryView;
	
	NoteObject *lastNote;
}

@property (assign) BOOL isPreviewOutdated;
@property (retain) WebView *preview;

-(IBAction)saveHTML:(id)sender;
-(IBAction)switchTabs:(id)sender;
-(IBAction)shareNote:(id)sender;
-(IBAction)shareAsk:(id)sender;
-(IBAction)cancelShare:(id)sender;

-(void)togglePreview:(id)sender;
-(void)requestPreviewUpdate:(NSNotification *)notification;
+(void)createCustomFiles;
-(SEL)markupProcessorSelector:(NSInteger)previewMode;
- (NSString *)urlEncodeValue:(NSString *)str;
- (void)showShareURL:(NSString *)url isError:(BOOL)isError;
- (IBAction)hideShareURL:(id)sender;
- (IBAction)openShareURL:(id)sender;
+(NSString *)css;
+(NSString *)html;
@end
