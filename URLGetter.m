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


#import "URLGetter.h"

@interface URLGetter ()
@property (nonatomic, retain, readwrite) NSString *downloadPath;
@property (nonatomic, retain) NSString *tempDirectory;
@property (nonatomic, retain) NSURLSession *session;
@property (nonatomic, retain) NSURLSessionDownloadTask *downloadTask;
@end

@implementation URLGetter

@synthesize url, userData, downloadPath, delegate, tempDirectory, session, downloadTask;

- (id)initWithURL:(NSURL*)aUrl delegate:(id)aDelegate userData:(id)someObj {
	if (!aUrl || [aUrl isFileURL]) {
		return nil;
	}
	self = [super init];
	if (self) {
		maxExpectedByteCount = 0;
		isImporting = isIndicating = NO;
		delegate = aDelegate;
		url = [aUrl retain];
		userData = [someObj retain];
		totalReceivedByteCount = 0;
		didComplete = NO;
		
		NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
		NSURLSession *createdSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
		NSURLSessionDownloadTask *task = [createdSession downloadTaskWithURL:url];
		if (!task) {
			[createdSession invalidateAndCancel];
			[self release];
			return nil;
		}
		self.session = createdSession;
		self.downloadTask = task;
		[self.downloadTask resume];

		[self startProgressIndication:self];
	}
	
	return self;
}

- (void)dealloc {
	if (downloadTask) {
		[downloadTask cancel];
		[downloadTask release];
	}
	if (session) {
		[session invalidateAndCancel];
		[session release];
	}
	[downloadPath release];
	[tempDirectory release];
	[url release];
	[userData release];
	[urlGetterTopLevelObjects release];
	
	[super dealloc];
}

- (IBAction)cancelDownload:(id)sender {
	if (downloadTask) {
		[downloadTask cancel];
	}
	[self endDownloadWithPath:nil];
}

- (void)stopProgressIndication {
	[window close];
	[progress stopAnimation:nil];
	
	isImporting = isIndicating = NO;
}

- (void)startProgressIndication:(id)sender {
	if (!window) {
		NSArray *topLevelObjects = nil;
		if (![[NSBundle mainBundle] loadNibNamed:@"URLGetter" owner:self topLevelObjects:&topLevelObjects])  {
			NSLog(@"Failed to load URLGetter.nib");
			NSBeep();
			return;
		}
		[urlGetterTopLevelObjects release];
		urlGetterTopLevelObjects = [topLevelObjects retain];
		[progress setUsesThreadedAnimation:YES];
	}
	
	[progress setIndeterminate:YES];
	[progress startAnimation:nil];
	
	[cancelButton setEnabled:YES];
	[progressStatus setStringValue:NSLocalizedString(@"Download: waiting to begin.", @"download dialog status message")];
	[objectURLStatus setStringValue:[url absoluteString]];
	
	[window center];
	[window makeKeyAndOrderFront:sender];
	
	isIndicating = YES;
}

- (void)updateProgress {
	if (isIndicating) {
		[progress setIndeterminate:!maxExpectedByteCount || isImporting];
		[progress setMaxValue:(double)maxExpectedByteCount];
		
		[progress setDoubleValue:(double)totalReceivedByteCount];
		if (isImporting) {
			[progressStatus setStringValue:NSLocalizedString(@"Importing content...", @"Status message after downloading a URL")];
		} else if (maxExpectedByteCount > 0) {
			[progressStatus setStringValue:[NSString stringWithFormat:NSLocalizedString(@"%.0lf KB of %.0lf KB", nil), 
				(double)totalReceivedByteCount / 1024.0, (double)maxExpectedByteCount / 1024.0]];
		} else {
			[progressStatus setStringValue:[NSString stringWithFormat:NSLocalizedString(@"%.0lf KB received",nil), (double)totalReceivedByteCount / 1024.0]];
		}
	}
}


- (void)URLSession:(NSURLSession *)unusedSession downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
	#pragma unused(unusedSession)
	#pragma unused(bytesWritten)
	if (task != downloadTask) {
		return;
	}
	
	totalReceivedByteCount = totalBytesWritten;
	if (totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown) {
		maxExpectedByteCount = totalBytesExpectedToWrite;
	}
	
	[self updateProgress];
}

- (void)URLSession:(NSURLSession *)unusedSession downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
	#pragma unused(unusedSession)
	if (task != downloadTask) {
		return;
	}
	
	NSString *suggestedName = [[task response] suggestedFilename];
	if (![suggestedName length]) {
		suggestedName = [[url lastPathComponent] length] ? [url lastPathComponent] : @"download";
	}

	self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	NSError *mkErr = nil;
	if (![[NSFileManager defaultManager] createDirectoryAtPath:tempDirectory withIntermediateDirectories:YES attributes:nil error:&mkErr]) {
		NSLog(@"URLGetter: Couldn't create temporary directory! %@", mkErr.localizedDescription);
		[self presentDownloadError:mkErr];
		[self endDownloadWithPath:nil];
		return;
	}

	self.downloadPath = [tempDirectory stringByAppendingPathComponent:suggestedName];
	NSFileManager *fileMan = [NSFileManager defaultManager];
	NSURL *destinationURL = [NSURL fileURLWithPath:downloadPath];
	if ([fileMan fileExistsAtPath:downloadPath]) {
		[fileMan removeItemAtPath:downloadPath error:NULL];
	}

	NSError *moveError = nil;
	if (![fileMan moveItemAtURL:location toURL:destinationURL error:&moveError]) {
		NSLog(@"URLGetter: Couldn't move downloaded file to %@: %@", downloadPath, moveError.localizedDescription);
		[self presentDownloadError:moveError];
		[self endDownloadWithPath:nil];
		return;
	}

	[self endDownloadWithPath:downloadPath];
}

- (void)URLSession:(NSURLSession *)unusedSession task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
	#pragma unused(unusedSession)
	if ((NSURLSessionDownloadTask *)task != downloadTask) {
		return;
	}
	
	if (error) {
		if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
			return;
		}
		[self presentDownloadError:error];
		[self endDownloadWithPath:nil];
	}
}

- (void)presentDownloadError:(NSError *)error {
	NSString *reason = [error localizedDescription];
	if (!reason) {
		reason = NSLocalizedString(@"unknown error.", @"error description of last resort for why a URL couldn't be accessed");
	}
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"The URL quotemark%@quotemark could not be accessed: %@.", nil),
		[url absoluteString], reason]];
	[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert runModal];
}

- (void)endDownloadWithPath:(NSString*)path {
	if (didComplete) {
		return;
	}
	didComplete = YES;

	isImporting = YES;
	[self updateProgress];

	[self retain];
	[delegate URLGetter:self returnedDownloadedFile:path];
	
	//clean up after ourselves
	NSFileManager *fileMan = [NSFileManager defaultManager];
	if (downloadPath) {
		NSError *removeError = nil;
		if (![fileMan removeItemAtPath:downloadPath error:&removeError] && removeError) {
			NSLog(@"URLGetter: Couldn't remove downloaded file %@: %@", downloadPath, removeError.localizedDescription);
		}
		self.downloadPath = nil;
	}

	if (tempDirectory) {
		//only remove temporary directory if there's nothing in it
		NSError *contentsError = nil;
		NSArray *remainingItems = [fileMan contentsOfDirectoryAtPath:tempDirectory error:&contentsError];
		if (!remainingItems && contentsError) {
			NSLog(@"URLGetter: Couldn't inspect temporary directory %@: %@", tempDirectory, contentsError.localizedDescription);
		}
		if ([remainingItems count] == 0) {
			NSError *removeDirError = nil;
			if (![fileMan removeItemAtPath:tempDirectory error:&removeDirError] && removeDirError) {
				NSLog(@"URLGetter: Couldn't remove temporary directory %@: %@", tempDirectory, removeDirError.localizedDescription);
			}
		} else {
			NSLog(@"note removing %@ because it still contains files!", tempDirectory);
		}
		self.tempDirectory = nil;
	}
	
	if (downloadTask) {
		self.downloadTask = nil;
	}
	if (session) {
		[session invalidateAndCancel];
		self.session = nil;
	}
	
	[self stopProgressIndication];
	
	[self release];
}

@end
