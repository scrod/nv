//
//  PreviewController.h
//  Notation
//
//  Created by Christian Tietze on 15.10.10.
//  Copyright 2010

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class AppController;

@interface PreviewController : NSWindowController 
{
    IBOutlet WebView *preview;
	IBOutlet NSTextView *sourceView;
	IBOutlet NSTabView *tabView;
	IBOutlet NSButton *tabSwitcher;
	IBOutlet NSButton *shareButton;
    BOOL isPreviewOutdated;
//    IBOutlet NSWindow *wnd;
}

@property (assign) BOOL isPreviewOutdated;
@property (retain) WebView *preview;

-(IBAction)saveHTML:(id)sender;
-(IBAction)switchTabs:(id)sender;
-(IBAction)shareNote:(id)sender;
-(void)togglePreview:(id)sender;
-(void)requestPreviewUpdate:(NSNotification *)notification;
+(void)createCustomFiles;
-(SEL)markupProcessorSelector:(NSInteger)previewMode;
- (NSString *)urlEncodeValue:(NSString *)str;
@end
