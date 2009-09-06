/* URLGetter */

#import <Cocoa/Cocoa.h>

@interface URLGetter : NSObject
{
    IBOutlet NSButton *cancelButton;
    IBOutlet NSTextField *objectURLStatus;
    IBOutlet NSProgressIndicator *progress;
    IBOutlet NSTextField *progressStatus;
    IBOutlet NSPanel *window;
	
	NSURL *url;
	NSURLDownload *downloader;
	NSString *downloadPath, *tempDirectory;
	
	id userData;
	
	id delegate;
	
	BOOL isIndicating;
	
	long long totalReceivedByteCount, maxExpectedByteCount;
}

- (IBAction)cancelDownload:(id)sender;
- (id)initWithURL:(NSURL*)aUrl delegate:(id)aDelegate userData:(id)someObj;

- (NSURL*)url;
- (id)userData;

- (id)delegate;
- (void)setDelegate:(id)aDelegate;

- (void)stopProgressIndication;
- (void)startProgressIndication:(id)sender;
- (void)updateProgress;
- (NSString*)downloadPath;

- (void)endDownloadWithPath:(NSString*)path;

@end

@interface URLGetter (Delegate)
- (void)URLGetter:(URLGetter*)getter returnedDownloadedFile:(NSString*)filename;
@end
