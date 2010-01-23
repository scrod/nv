//
//  SyncResponseFetcher.h
//  Notation
//
//  Created by Zachary Schneirov on 11/29/09.
//  Copyright 2009 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>


//carries out a single request

@interface SyncResponseFetcher : NSObject {

	NSMutableData *receivedData;
	NSData *dataToSend;
	NSURLConnection *urlConnection;
	NSURL *requestURL;
	NSDictionary *headers;
	id representedObject;
	
	NSString *lastErrorMessage;
	NSInteger lastStatusCode;
	
	NSInvocation *successInvocation;
	id delegate;
	BOOL isRunning;
}

- (id)initWithURL:(NSURL*)aURL bodyStringAsUTF8B64:(NSString*)stringToEncode delegate:(id)aDelegate;
- (id)initWithURL:(NSURL*)aURL POSTData:(NSData*)POSTData delegate:(id)aDelegate;
- (void)setRepresentedObject:(id)anObject;
- (id)representedObject;
- (NSInvocation*)successInvocation;
- (NSURL*)requestURL;
- (NSDictionary*)headers;
- (NSInteger)statusCode;
- (NSString*)errorMessage;
- (void)_fetchDidFinishWithError:(NSString*)anErrString;
- (id)delegate;
- (BOOL)start;
- (BOOL)startWithSuccessInvocation:(NSInvocation*)anInvocation;
- (BOOL)isRunning;
- (void)cancel;
@end


@interface NSObject (SyncResponseFetcherDelegate)

- (void)syncResponseFetcher:(SyncResponseFetcher*)fetcher receivedData:(NSData*)data returningError:(NSString*)errString;

@end
