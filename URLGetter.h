/* URLGetter */

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


#import <Cocoa/Cocoa.h>

@protocol NSURLDownloadDelegate;

@interface URLGetter : NSObject <NSURLDownloadDelegate>
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
