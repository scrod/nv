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
    }
    return self;
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
    AppController *app = object;
    NSString *rawString = [app noteContent];
    SEL mode = [self markupProcessorSelector:[app currentPreviewMode]];
    NSString *processedString = [NSString performSelector:mode withObject:rawString];
	NSString* cssString = [[self class] css];
    NSString* htmlString = [[self class] html];
	NSMutableString *outputString = [NSMutableString stringWithString:(NSString *)htmlString];
	[outputString replaceOccurrencesOfString:@"{%content%}" withString:processedString options:0 range:NSMakeRange(0, [outputString length])];
	[outputString replaceOccurrencesOfString:@"{%style%}" withString:cssString options:0 range:NSMakeRange(0, [outputString length])];

    [[preview mainFrame] loadHTMLString:outputString baseURL:nil];
    [sourceView replaceCharactersInRange:NSMakeRange(0, [[sourceView string] length]) withString:processedString];
    self.isPreviewOutdated = NO;
}

-(SEL)markupProcessorSelector:(NSInteger)previewMode
{
    if (previewMode == MarkdownPreview) {
        return @selector(stringWithProcessedMarkdown:);
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
		NSString *cssString = @"body,p,td,div { \n  font-family:Helvetica,Arial,sans-serif;\n  line-height:1.4em;\n  font-size:14px;\n  color:#111; }\np { margin:0 0 1.7em 0; }\na { \n	color:rgb(13,110,161); \n	text-decoration:none; \n	-webkit-transition:color .2s ease-in-out;\n}\na:hover { color:#3593d9; }\nh1 { font-size:24px; color:#000; margin:12px 0 15px 0; }\nh2 { \n  font-size:20px; \n  color:#111;\n  width:auto;\n  margin:15px 0 10px 2px; }\nh2 em { \n  line-height:1.6em;\n  font-size:12px;\n  color:#111;\n  text-shadow:0 1px 0 #FFF;\n  padding-left:10px; }\nh3 { font-size:20px; color:#111; }\nh4 { font-size:14px; color:#111; margin-bottom:1.3em; }\n.footnote { \n  font-size:.8em;\n  vertical-align:super;\n  color:rgb(13,110,161); }\n#wrapper {\n  background: -webkit-gradient(linear, left top, left bottom, color-stop(0.56, #FFFFFF), color-stop(1.00, #D4CFC8));\n  position:fixed;\n  top:0;\n  left:0;\n  right:0;\n  bottom:0;\n  -webkit-box-shadow: inset 0px 0px 4px #8F8D87;\n}\n#contentdiv {\n  position:fixed;\n  top:5px;\n  left:5px;\n  right:5px;\n  bottom:5px;\n  background: transparent;	\n  color: #303030;\n  overflow:auto;\n  text-indent:20px;\n  padding:10px;\n}\n#contentdiv::-webkit-scrollbar { width: 6px; }\n#contentdiv::-webkit-scrollbar:horizontal { height:6px; display:none; }\n#contentdiv::-webkit-scrollbar-track { background:transparent;-webkit-border-radius:0;right:10px; }\n#contentdiv::-webkit-scrollbar-track:disabled { display: none; }\n#contentdiv::-webkit-scrollbar-thumb { border-width: 0;min-height: 20px;background:#777;opacity: 0.4;-webkit-border-radius: 5px; }";
		
		NSData *cssData = [NSData dataWithBytes:[cssString UTF8String] length:[cssString length]];
		[fileManager createFileAtPath:cssFile contents:cssData attributes:nil];
    }
	
	NSString *htmlFileName = @"template.html";
	NSString *htmlFile = [folder stringByAppendingPathComponent: htmlFileName];
	
	if ([fileManager fileExistsAtPath:htmlFile] == NO)
	{
		NSString *htmlString = @"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN\"\n	\"http://www.w3.org/Math/DTD/mathml2/xhtml-math11-f.dtd\">\n\n<html xmlns=\"http://www.w3.org/1999/xhtml\">\n	<head>\n		<meta name=\"Format\" content=\"complete\" />\n		<meta name=\"format\" content=\"complete\" />\n		<script src=\"http://www.google.com/jsapi\"></script>\n		<script>google.load(\"jquery\", \"1.4\");</script>\n    <style type=\"text/css\">{%style%}</style>\n	</head>\n<body>\n  <div id=\"wrapper\">\n    <div id=\"contentdiv\">\n      {%content%}\n    </div>\n  </div>\n</body>\n</html>";
		
		NSData *htmlData = [NSData dataWithBytes:[htmlString UTF8String] length:[htmlString length]];
		[fileManager createFileAtPath:htmlFile contents:htmlData attributes:nil];
    }
	
}


-(IBAction)saveHTML:(id)sender
{
    // TODO high coupling; too many assumptions on architecture:
    AppController *app = [[NSApplication sharedApplication] delegate];
    NSString *rawString = [app noteContent];
    NSString *processedString = [NSString documentWithProcessedMultiMarkdown:rawString];
	
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    NSArray *fileTypes = [[NSArray alloc] initWithObjects:@"html",@"xhtml",@"htm",nil];
    [savePanel setAllowedFileTypes:fileTypes];
    
    if ([savePanel runModal] == NSFileHandlingPanelOKButton) {
        NSURL *file = [savePanel URL];
        NSError *error;
        [processedString writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
        
    }
    
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

@end
