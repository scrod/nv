//
//  SyncResponseFetcher.h
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
	BOOL isRunning, didCancel;
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
- (BOOL)didCancel;
- (void)cancel;
@end


@interface NSObject (SyncResponseFetcherDelegate)

- (void)syncResponseFetcher:(SyncResponseFetcher*)fetcher receivedData:(NSData*)data returningError:(NSString*)errString;

@end
