//
//  PreviewController.m
//  Notation
//
//  Created by Christian Tietze on 15.10.10.
//  Copyright 2010

#import "PreviewController.h"
#import "AppController.h" // TODO for the defines only, can you get around that?
#import "AppController_Preview.h"
#import "NSString_MultiMarkdown.h"
#import "NSString_Markdown.h"
#import "NSString_Textile.h"

#define kDefaultMarkupPreviewVisible @"markupPreviewVisible"

@interface NSString (MIMEAdditions)
+ (NSString*)MIMEBoundary;
+ (NSString*)multipartMIMEStringWithDictionary:(NSDictionary*)dict;
@end

@implementation NSString (MIMEAdditions)
//this returns a unique boundary which is used in constructing the multipart MIME body of the POST request
+ (NSString*)MIMEBoundary
{
    static NSString* MIMEBoundary = nil;
    if(!MIMEBoundary)
        MIMEBoundary = [[NSString alloc] initWithFormat:@"----_=_nvALT_%@_=_----",[[NSProcessInfo processInfo] globallyUniqueString]];
    return MIMEBoundary;
}
//this create a correctly structured multipart MIME body for the POST request from a dictionary
+ (NSString*)multipartMIMEStringWithDictionary:(NSDictionary*)dict 
{
    NSMutableString* result = [NSMutableString string];
    for (NSString* key in dict)
    {
        [result appendFormat:@"--%@\nContent-Disposition: form-data; name=\"%@\"\n\n%@\n",[NSString MIMEBoundary],key,[dict objectForKey:key]];
    }
    [result appendFormat:@"\n--%@--\n",[NSString MIMEBoundary]];
    return result;
}
@end

@implementation PreviewController

@synthesize preview;
@synthesize isPreviewOutdated;

+(void)initialize
{
    NSDictionary *appDefaults = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:NO]
                                                            forKey:kDefaultMarkupPreviewVisible];
    
    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
}

-(id)init
{
    if ((self = [super initWithWindowNibName:@"MarkupPreview" owner:self])) {
        self.isPreviewOutdated = YES;
        [[self class] createCustomFiles];
        BOOL showPreviewWindow = [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultMarkupPreviewVisible];
        if (showPreviewWindow) {
            [[self window] orderFront:self];
        }
		[sourceView setTextContainerInset:NSMakeSize(20,20)];
		[tabView selectTabViewItem:[tabView tabViewItemAtIndex:0]];
		[tabSwitcher setTitle:@"View Source"];
//		[preview setPolicyDelegate:self];
//		[preview setUIDelegate:self];
    }
    return self;
}

-(void)awakeFromNib
{
	AppController *app = [[NSApplication sharedApplication] delegate];;
	cssString = [[[self class] css] retain];
    htmlString = [[[self class] html] retain];
	lastNote = [app selectedNoteObject];
}

//this returns a nice name for the method in the JavaScript environment
+(NSString*)webScriptNameForSelector:(SEL)sel
{
    if(sel == @selector(logJavaScriptString:))
        return @"log";
    return nil;
}

//this allows JavaScript to call the -logJavaScriptString: method
+ (BOOL)isSelectorExcludedFromWebScript:(SEL)sel
{
    if(sel == @selector(logJavaScriptString:))
        return NO;
    return YES;
}

//this is a simple log command
- (void)logJavaScriptString:(NSString*) logText
{
    NSLog(@"JavaScript: %@",logText);
}

//this is called as soon as the script environment is ready in the webview
- (void)webView:(WebView *)sender didClearWindowObject:(WebScriptObject *)windowScriptObject forFrame:(WebFrame *)frame
{
    //add the controller to the script environment
    //the "Cocoa" object will now be available to JavaScript
    [windowScriptObject setValue:self forKey:@"Cocoa"];
}

// Above webView methods from <http://stackoverflow.com/questions/2288582/embedded-webkit-script-callbacks-how/2293305#2293305>

- (void)webView:(WebView *)sender decidePolicyForNavigationAction:(NSDictionary *)actionInformation request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id<WebPolicyDecisionListener>)listener {
	NSString *targetURL = [[request URL] scheme];

    if ([targetURL isEqual:@"http"]) {
		[[NSWorkspace sharedWorkspace] openURL:[request URL]];
        [listener ignore];	
    } else {
		[listener use];
	}
}

- (void)webView:(WebView *)sender decidePolicyForNewWindowAction:(NSDictionary *)actionInformation request:(NSURLRequest *)request newFrameName:(NSString *)frameName decisionListener:(id<WebPolicyDecisionListener>)listener {
	NSLog(@"NEW WIN ACTION SENDER: %@",sender);
    [[NSWorkspace sharedWorkspace] openURL:[actionInformation objectForKey:WebActionOriginalURLKey]];
    [listener ignore];
}

-(void)requestPreviewUpdate:(NSNotification *)notification
{
    if (![[self window] isVisible]) {
        self.isPreviewOutdated = YES;
        return;
    }
    
    AppController *app = [notification object];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(preview:) object:app];
    
    [self performSelector:@selector(preview:) withObject:app afterDelay:0.5];
}

-(void)togglePreview:(id)sender
{
    NSWindow *wnd = [self window];
    
    if ([wnd isVisible]) {
		if (attachedWindow) {
			[[shareButton window] removeChildWindow:attachedWindow];
			[attachedWindow orderOut:self];
			[attachedWindow release];
			attachedWindow = nil;
			[shareURL release];
		}
        [wnd orderOut:self];
    } else {
        if (self.isPreviewOutdated) {
            // TODO high coupling; too many assumptions on architecture:
            [self performSelector:@selector(preview:) withObject:[[NSApplication sharedApplication] delegate] afterDelay:0.0];
        }
		[tabView selectTabViewItem:[tabView tabViewItemAtIndex:0]];
		[tabSwitcher setTitle:@"View Source"];

        [wnd orderFront:self];
    }
    
    // save visibility to defaults
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:[wnd isVisible]]
                                              forKey:kDefaultMarkupPreviewVisible];
}

-(void)windowWillClose:(NSNotification *)notification
{
	[[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:NO]
                                              forKey:kDefaultMarkupPreviewVisible];
}

+(NSString*)css {
	NSFileManager *mgr = [NSFileManager defaultManager];
	
	NSString *folder = @"~/Library/Application Support/Notational Velocity/";
	folder = [folder stringByExpandingTildeInPath];
	NSString *cssFileName = @"custom.css";
	NSString *customCSSPath = [folder stringByAppendingPathComponent: cssFileName];
	
	if (![mgr fileExistsAtPath:customCSSPath]) {
		[[self class] createCustomFiles];
	}
	return [NSString stringWithContentsOfFile:customCSSPath
													encoding:NSUTF8StringEncoding
													   error:NULL];
	
}

+(NSString*)html {
	NSFileManager *mgr = [NSFileManager defaultManager];
	
    NSString *folder = @"~/Library/Application Support/Notational Velocity/";
	folder = [folder stringByExpandingTildeInPath];
	NSString *htmlFileName = @"template.html";
	NSString *customHTMLPath = [folder stringByAppendingPathComponent: htmlFileName];
	        
	if (![mgr fileExistsAtPath:customHTMLPath]) {
		[[self class] createCustomFiles];
	}
	return [NSString stringWithContentsOfFile:customHTMLPath
													 encoding:NSUTF8StringEncoding
														error:NULL];
}

-(void)preview:(id)object
{
	NSString *lastScrollPosition = [[preview windowScriptObject] evaluateWebScript:@"document.getElementById('contentdiv').scrollTop"];
	AppController *app = object;
	NSString *rawString = [app noteContent];
	SEL mode = [self markupProcessorSelector:[app currentPreviewMode]];
	NSString *processedString = [NSString performSelector:mode withObject:rawString];
	NSMutableString *outputString = [NSMutableString stringWithString:(NSString *)htmlString];
	NSString *noteTitle =  ([app selectedNoteObject]) ? [NSString stringWithFormat:@"%@",titleOfNote([app selectedNoteObject])] : @"";
	
	if (lastNote == [app selectedNoteObject]) {
		NSString *restoreScrollPosition = [NSString stringWithFormat:@"\n<script>window.onload = function(){var div = document.getElementById('contentdiv'),oldscroll = %@;div.scrollTop = oldscroll;}</script>",lastScrollPosition];
		processedString = [processedString stringByAppendingString:restoreScrollPosition];
	} else {
		[cssString release];
		[htmlString release];
		cssString = [[[self class] css] retain];
		htmlString = [[[self class] html] retain];
		lastNote = [app selectedNoteObject];
	}
	NSString *nvSupportPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Notational Velocity"];
	[outputString replaceOccurrencesOfString:@"{%support%}" withString:nvSupportPath options:0 range:NSMakeRange(0, [outputString length])];
	[outputString replaceOccurrencesOfString:@"{%title%}" withString:noteTitle options:0 range:NSMakeRange(0, [outputString length])];
	[outputString replaceOccurrencesOfString:@"{%content%}" withString:processedString options:0 range:NSMakeRange(0, [outputString length])];
	[outputString replaceOccurrencesOfString:@"{%style%}" withString:cssString options:0 range:NSMakeRange(0, [outputString length])];
	
	[[preview mainFrame] loadHTMLString:outputString baseURL:nil];
	[sourceView replaceCharactersInRange:NSMakeRange(0, [[sourceView string] length]) withString:processedString];
    self.isPreviewOutdated = NO;
}

-(SEL)markupProcessorSelector:(NSInteger)previewMode
{
    if (previewMode == MarkdownPreview) {
		previewMode = MultiMarkdownPreview;
        return @selector(stringWithProcessedMultiMarkdown:);
    } else if (previewMode == MultiMarkdownPreview) {
        return @selector(stringWithProcessedMultiMarkdown:);
    } else if (previewMode == TextilePreview) {
        return @selector(stringWithProcessedTextile:);
    }
    
    return nil;
}

+ (void) createCustomFiles
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
    
	NSString *folder = @"~/Library/Application Support/Notational Velocity/";
	folder = [folder stringByExpandingTildeInPath];
	NSString *cssFileName = @"custom.css";
	NSString *cssFile = [folder stringByAppendingPathComponent: cssFileName];
	
	if ([fileManager fileExistsAtPath: folder] == NO)
	{
		[fileManager createDirectoryAtPath: folder attributes: nil];
		    
	}
	if ([fileManager fileExistsAtPath:cssFile] == NO)
	{
		NSString *cssString = @"body,p,td,div { font-family:Helvetica,Arial,sans-serif;line-height:1.4em;font-size:14px;color:#111; }\np { margin:0 0 1.7em 0; }\na { color:rgb(13,110,161);text-decoration:none;-webkit-transition:color .2s ease-in-out; }\na:hover { color:#3593d9; }\nh1.doctitle { background:#eee;font-size:14px;font-weight:bold;color:#333;line-height:25px;margin:0;padding:0 10px;border-bottom:solid 1px #aaa; }\nh1 { font-size:24px;color:#000;margin:12px 0 15px 0; }\nh2 { font-size:20px;color:#111;width:auto;margin:15px 0 10px 2px; }\nh2 em { line-height:1.6em;font-size:12px;color:#111;text-shadow:0 1px 0 #FFF;padding-left:10px; }\nh3 { font-size:20px;color:#111; }\nh4 { font-size:14px;color:#111;margin-bottom:1.3em; }\n.footnote { font-size:.8em;vertical-align:super;color:rgb(13,110,161); }\n#wrapper { background:#fff;position:fixed;top:0;left:0;right:0;bottom:0;-webkit-box-shadow:inset 0px 0px 4px #8F8D87; }\n#contentdiv { position:fixed;top:27px;left:5px;right:5px;bottom:5px;background:transparent;color:#303030;overflow:auto;text-indent:0px;padding:10px; }\n#contentdiv::-webkit-scrollbar { width:6px; }\n#contentdiv::-webkit-scrollbar:horizontal { height:6px;display:none; }\n#contentdiv::-webkit-scrollbar-track { background:transparent;-webkit-border-radius:0;right:10px; }\n#contentdiv::-webkit-scrollbar-track:disabled { display:none; }\n#contentdiv::-webkit-scrollbar-thumb { border-width:0;min-height:20px;background:#777;opacity:0.4;-webkit-border-radius:5px; }";
		
		NSData *cssData = [NSData dataWithBytes:[cssString UTF8String] length:[cssString length]];
		[fileManager createFileAtPath:cssFile contents:cssData attributes:nil];
    }
	
	NSString *htmlFileName = @"template.html";
	NSString *htmlFile = [folder stringByAppendingPathComponent: htmlFileName];
	
	if ([fileManager fileExistsAtPath:htmlFile] == NO)
	{
		NSString *htmlString = @"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN\"\n	\"http://www.w3.org/Math/DTD/mathml2/xhtml-math11-f.dtd\">\n\n<html xmlns=\"http://www.w3.org/1999/xhtml\">\n	<head>\n		<meta name=\"Format\" content=\"complete\" />\n		<meta name=\"format\" content=\"complete\" />\n    <style type=\"text/css\">{%style%}</style>\n	</head>\n<body>\n  <div id=\"wrapper\">\n	<h1 class=\"doctitle\">{%title%}</h1>\n    <div id=\"contentdiv\">\n      {%content%}\n    </div>\n  </div>\n</body>\n</html>";
		
		NSData *htmlData = [NSData dataWithBytes:[htmlString UTF8String] length:[htmlString length]];
		[fileManager createFileAtPath:htmlFile contents:htmlData attributes:nil];
    }
	
}

- (NSString *)urlEncodeValue:(NSString *)str
{
	NSString *result = (NSString *) CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (CFStringRef)str, NULL, CFSTR("?=&+"), kCFStringEncodingUTF8);
	return [result autorelease];
}


-(IBAction)shareNote:(id)sender
{
    AppController *app = [[NSApplication sharedApplication] delegate];
	NSString *noteTitle = [NSString stringWithFormat:@"%@",titleOfNote([app selectedNoteObject])];
    NSString *rawString = [app noteContent];
    SEL mode = [self markupProcessorSelector:[app currentPreviewMode]];
    NSString *processedString = [NSString performSelector:mode withObject:rawString];
	
	
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] 
                                    initWithURL:
                                    [NSURL URLWithString:@"http://peg.gd/nvapi.php"]];
    [request setHTTPMethod:@"POST"];
    [request addValue:@"8bit" forHTTPHeaderField:@"Content-Transfer-Encoding"];
    [request addValue: [NSString stringWithFormat:@"multipart/form-data; boundary=%@",[NSString MIMEBoundary]] forHTTPHeaderField: @"Content-Type"];
    NSDictionary* postData = [NSDictionary dictionaryWithObjectsAndKeys:
							  @"8c4205ec33d8f6caeaaaa0c10a14138c", @"key",
							  noteTitle, @"title",
							  processedString, @"body",
							  nil];
    [request setHTTPBody: [[NSString multipartMIMEStringWithDictionary: postData] dataUsingEncoding: NSUTF8StringEncoding]];
	NSHTTPURLResponse * response = nil;
	NSError * error = nil;
	NSData * responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
	NSString * responseString = [[[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding] autorelease];
	NSLog(@"RESPONSE STRING: %@", responseString);
	NSLog(@"%d",response.statusCode);
	shareURL = [[NSString stringWithString:responseString] retain];
	if (response.statusCode == 200) {
		[self showShareURL:[NSString stringWithFormat:@"View %@",shareURL] isError:NO];
	} else {
		[self showShareURL:@"Error connecting" isError:YES];
	}

	[request release];
	
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    [receivedData setLength:0];
}


- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    [receivedData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSLog(@"Succeeded! Received %d bytes of data",[receivedData length]);
	
	NSString * responseString = [[[NSString alloc] initWithData:receivedData encoding:NSASCIIStringEncoding] autorelease];
	NSLog(@"RESPONSE STRING: %@", responseString);
    [receivedData release];
}

- (void)savePanelDidEnd:(NSSavePanel *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	if (returnCode == NSFileHandlingPanelOKButton) {
		
		AppController *app = [[NSApplication sharedApplication] delegate];
		NSString *rawString = [app noteContent];
		NSString *processedString = [[NSString alloc] init];

		if ([app currentPreviewMode] == MarkdownPreview) {
			processedString = [NSString stringWithProcessedMarkdown:rawString];
		} else if ([app currentPreviewMode] == MultiMarkdownPreview) {
			processedString = ( [includeTemplate state] == NSOnState ) ? [NSString documentWithProcessedMultiMarkdown:rawString] : [NSString xhtmlWithProcessedMultiMarkdown:rawString];
		} else if ([app currentPreviewMode] == TextilePreview) {
			processedString = ( [includeTemplate state] == NSOnState ) ? [NSString documentWithProcessedTextile:rawString] : [NSString xhtmlWithProcessedTextile:rawString];
		}

        NSURL *file = [sheet URL];
        NSError *error;
        [processedString writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
    }
}

-(IBAction)saveHTML:(id)sender
{
	if (!accessoryView) {
		if (![NSBundle loadNibNamed:@"SaveHTMLPreview" owner:self]) {
			NSLog(@"Failed to load SaveHTMLPreview.nib");
			NSBeep();
			return;
		}
	}
    // TODO high coupling; too many assumptions on architecture:
    AppController *app = [[NSApplication sharedApplication] delegate];
	
    NSSavePanel *savePanel = [NSSavePanel savePanel];
	[savePanel setAccessoryView:accessoryView];
	[savePanel setCanCreateDirectories:YES];
	[savePanel setCanSelectHiddenExtension:YES];
	
    NSArray *fileTypes = [[NSArray alloc] initWithObjects:@"html",@"xhtml",@"htm",nil];
    [savePanel setAllowedFileTypes:fileTypes];

	NSString *noteTitle =  ([app selectedNoteObject]) ? [NSString stringWithFormat:@"%@",titleOfNote([app selectedNoteObject])] : @"";
    [savePanel beginSheetForDirectory:nil file:noteTitle modalForWindow:[self window] modalDelegate:self 
					   didEndSelector:@selector(savePanelDidEnd:returnCode:contextInfo:) contextInfo:nil];
    
    [fileTypes release];
}

-(IBAction)switchTabs:(id)sender
{
	int tabSelection = [tabView indexOfTabViewItem:[tabView selectedTabViewItem]];

	if (tabSelection == 0) {
		[tabSwitcher setTitle:@"View Preview"];
		[tabView selectTabViewItem:[tabView tabViewItemAtIndex:1]];
	} else {
		[tabSwitcher setTitle:@"View Source"];
		[tabView selectTabViewItem:[tabView tabViewItemAtIndex:0]];
	}
}

- (IBAction)shareAsk:(id)sender
{
	if (!confirmWindow && !attachedWindow) {
        int side = 3;
        NSPoint buttonPoint = NSMakePoint(NSMidX([shareButton frame]),
                                          NSMidY([shareButton frame]));
        confirmWindow = [[MAAttachedWindow alloc] initWithView:shareConfirmation 
                                                attachedToPoint:buttonPoint 
                                                       inWindow:[shareButton window]
                                                         onSide:side 
                                                     atDistance:15.0f];
        [confirmWindow setBorderColor:[NSColor colorWithCalibratedHue:0.278 saturation:0.000 brightness:0.871 alpha:0.950]];
        [confirmWindow setBackgroundColor:[NSColor colorWithCalibratedRed:0.134 green:0.134 blue:0.134 alpha:0.950]];
        [confirmWindow setViewMargin:3.0f];
        [confirmWindow setBorderWidth:1.0f];
        [confirmWindow setCornerRadius:10.0f];
        [confirmWindow setHasArrow:YES];
        [confirmWindow setDrawsRoundCornerBesideArrow:YES];
        [confirmWindow setArrowBaseWidth:10.0f];
        [confirmWindow setArrowHeight:6.0f];
        
        [[shareButton window] addChildWindow:confirmWindow ordered:NSWindowAbove];
		
    } else {
		if (confirmWindow)
			[self cancelShare:self];
		else if (attachedWindow)
			[self hideShareURL:self];
	}
}

- (void)showShareURL:(NSString *)url isError:(BOOL)isError
{
	if (confirmWindow) {
		[[shareButton window] removeChildWindow:confirmWindow];
		[confirmWindow orderOut:self];
		[confirmWindow release];
		confirmWindow = nil;
	}
		// Attach/detach window
    if (!attachedWindow) {
        int side = 3;
        NSPoint buttonPoint = NSMakePoint(NSMidX([shareButton frame]),
                                          NSMidY([shareButton frame]));
        attachedWindow = [[MAAttachedWindow alloc] initWithView:shareNotification 
                                                attachedToPoint:buttonPoint 
                                                       inWindow:[shareButton window]
                                                         onSide:side 
                                                     atDistance:15.0f];
        [attachedWindow setBorderColor:[NSColor colorWithCalibratedHue:0.278 saturation:0.000 brightness:0.871 alpha:0.950]];
        [attachedWindow setBackgroundColor:[NSColor colorWithCalibratedRed:0.134 green:0.134 blue:0.134 alpha:0.950]];
        [attachedWindow setViewMargin:3.0f];
        [attachedWindow setBorderWidth:1.0f];
        [attachedWindow setCornerRadius:10.0f];
        [attachedWindow setHasArrow:YES];
        [attachedWindow setDrawsRoundCornerBesideArrow:YES];
        [attachedWindow setArrowBaseWidth:10.0f];
        [attachedWindow setArrowHeight:6.0f];
        
        [[shareButton window] addChildWindow:attachedWindow ordered:NSWindowAbove];
		
    }
	
	if (isError) {
		[urlTextField setStringValue:url];
		[viewOnWebButton setHidden:YES];
	} else {
		NSPasteboard *pb = [NSPasteboard generalPasteboard];
		NSArray *types = [NSArray arrayWithObjects:NSStringPboardType, nil];
		[pb declareTypes:types owner:self];
		[pb setString:shareURL forType:NSStringPboardType];
		[urlTextField setHidden:NO];
		[viewOnWebButton setTitle:url];		
	}


}

- (IBAction)hideShareURL:(id)sender
{
	[[shareButton window] removeChildWindow:attachedWindow];
	[attachedWindow orderOut:self];
	[attachedWindow release];
	attachedWindow = nil;
	[shareURL release];
}

- (IBAction)cancelShare:(id)sender
{
	[[shareButton window] removeChildWindow:confirmWindow];
	[confirmWindow orderOut:self];
	[confirmWindow release];
	confirmWindow = nil;
}

- (IBAction)openShareURL:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:shareURL]];
	[[shareButton window] removeChildWindow:attachedWindow];
	[attachedWindow orderOut:self];
	[attachedWindow release];
	attachedWindow = nil;
	[shareURL release];
}

- (void)dealloc {
    [htmlString release];
	[cssString release];
	[lastNote release];
	[super dealloc];
}
@end
