/* URLGetter */

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


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
	
	BOOL isIndicating, isImporting;
	
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
