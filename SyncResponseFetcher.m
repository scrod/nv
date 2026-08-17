//
//  SyncResponseFetcher.m
//  Notation
//
//  Created by Zachary Schneirov on 11/29/09.

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


#import "SyncResponseFetcher.h"
#import "NSData_transformations.h"

@interface SyncResponseFetcher ()
@property (nonatomic, retain, readwrite) NSInvocation *successInvocation;
@property (nonatomic, copy, readwrite) NSDictionary *headers;
@property (nonatomic, retain, readwrite) NSString *errorMessage;
@end

@implementation SyncResponseFetcher

@synthesize representedObject, successInvocation, requestURL, headers,
	errorMessage = lastErrorMessage, delegate, running = isRunning, didCancel;

+ (void)initialize {
	
	static BOOL initialized = NO;
    [super initialize];
    if (!initialized) {
		[[NSURLCache sharedURLCache] setDiskCapacity:0];
    }
}


- (id)initWithURL:(NSURL*)aURL bodyStringAsUTF8B64:(NSString*)stringToEncode delegate:(id)aDelegate {
	NSData *B64Data = nil;
	if (stringToEncode) {
		NSString *B64String = [[stringToEncode dataUsingEncoding:NSUTF8StringEncoding] encodeBase64WithoutNewlines];
		if (!(B64Data = [B64String dataUsingEncoding:NSASCIIStringEncoding])) {
			return nil;
		}
	}
	
	return [self initWithURL:aURL POSTData:B64Data delegate:aDelegate];
}

- (id)initWithURL:(NSURL*)aURL POSTData:(NSData*)POSTData delegate:(id)aDelegate {
	return [self initWithURL:aURL POSTData:POSTData contentType:nil delegate:aDelegate];
}

- (id)initWithURL:(NSURL*)aURL POSTData:(NSData*)POSTData contentType:(NSString*)contentType delegate:(id)aDelegate {
	self = [self init];
	if (self) {
		receivedData = [[NSMutableData alloc] init];
		requestURL = [aURL retain];
		delegate = aDelegate;
		dataToSend = [POSTData retain];
		dataToSendContentType = [contentType copy];
	}
	return self;
}

- (BOOL)startWithSuccessInvocation:(NSInvocation*)anInvocation {

	self.successInvocation = anInvocation;
	return [self start];
}

- (BOOL)start {
	
	if (isRunning) return YES;
	
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30.0];
	if (!request) {
		NSLog(@"%@: Couldn't create HTTP request with URL %@", NSStringFromSelector(_cmd), requestURL);
		return NO;
	}
	
	[request setHTTPShouldHandleCookies:NO];
	[request addValue:@"Sinus cardinalis NV 2.0B5" forHTTPHeaderField:@"User-agent"];
	
	//if POSTData is nil, do a plain GET request
	if (dataToSend) {
		if (dataToSendContentType) {
			[request addValue:dataToSendContentType forHTTPHeaderField:@"Content-Type"];
		}
		
		[request setHTTPBody:dataToSend];
		[request setHTTPMethod:@"POST"];
	}
	
	[self retain];
	[delegate retain];
	
	didCancel = NO;
	isRunning = YES;
	
	//NSLog(@"starting request for URL '%@'", requestURL);
	NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
	urlSession = [[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]] retain];
	if (!(urlTask = [[urlSession dataTaskWithRequest:request] retain])) {
		NSLog(@"%@: Couldn't create NSURLSessionDataTask with URLRequest %@", NSStringFromSelector(_cmd), request);
		[urlSession invalidateAndCancel];
		[urlSession release];
		urlSession = nil;
		isRunning = NO;
		[self release];
		[delegate release];
		return NO;
	}
	[urlTask resume];
	
	return YES;
}

- (void)cancel {
	if (!isRunning) return;
	
	didCancel = YES;
	
	[urlTask cancel];
	[self _fetchDidFinishWithError:NSLocalizedString(@"Operation cancelled", 
													 @"Error string returned to indicate that the user cancelled a syncing service operation")];
}

- (void)dealloc {
	
	[dataToSend release];
	[dataToSendContentType release];
	[requestURL release];
	[receivedData release];
	[urlTask cancel];
	[urlTask release];
	[urlSession invalidateAndCancel];
	[urlSession release];
	[headers release];
	[representedObject release];
	
	[super dealloc];
}

- (NSString*)description {
	return [NSString stringWithFormat:@"Fetcher(%p, %@)", self, requestURL];
}

- (void)_fetchDidFinishWithError:(NSString*)anErrString {
	
	if (!isRunning) {
		NSLog(@"not processing %@ because fetcher was already stopped; should not be called", NSStringFromSelector(_cmd));
		return;
	}
	//assumes that anErrString will always be provided in the case of any error, and thus indicates the presence of such
	[delegate syncResponseFetcher:self receivedData:anErrString ? nil : receivedData returningError:anErrString];

	//delegate just had another opportunity to stop us, so check to see if he did that
	if (!isRunning) {
		return;
	}
	
	if (!anErrString) [successInvocation invoke];
	
	self.successInvocation = nil;
	
	self.errorMessage = anErrString;
	
	[receivedData setLength:0];
	
	[urlTask release];
	urlTask = nil;
	[urlSession invalidateAndCancel];
	[urlSession release];
	urlSession = nil;
	isRunning = NO;
	
	[self autorelease];
	[delegate autorelease];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
	#pragma unused(session)
	if (dataTask != urlTask || !isRunning) {
		completionHandler(NSURLSessionResponseCancel);
		return;
	}

	[receivedData setLength:0];
	
	lastStatusCode = 0;
	BOOL responseValid = [response isKindOfClass:[NSHTTPURLResponse class]];
	if (!responseValid || (lastStatusCode = [(NSHTTPURLResponse*)response statusCode]) != 200) {
		completionHandler(NSURLSessionResponseCancel);
		[self _fetchDidFinishWithError:[NSHTTPURLResponse localizedStringForStatusCode:lastStatusCode]];
	} else if (responseValid) {
		self.headers = [(NSHTTPURLResponse*)response allHeaderFields];
		completionHandler(NSURLSessionResponseAllow);
	}
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
	#pragma unused(session)
	if (dataTask != urlTask || !isRunning) {
		return;
	}

	if (data) {
		[receivedData appendData:data];
	}
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
	#pragma unused(session)
	if (task != urlTask || !isRunning) {
		return;
	}

	[self _fetchDidFinishWithError:error ? [error localizedDescription] : nil];
}

@end
