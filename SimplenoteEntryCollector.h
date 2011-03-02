//
//  SimplenoteEntryCollector.h
//  Notation
//
//  Created by Zachary Schneirov on 12/4/09.

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

#import "SyncServiceSessionProtocol.h"

@class NoteObject;
@class DeletedNoteObject;
@class SyncResponseFetcher;

@interface SimplenoteEntryCollector : NSObject <SyncServiceTask> {
	NSArray *entriesToCollect;
	NSMutableArray *entriesCollected, *entriesInError;
	NSUInteger entryFinishedCount;
	NSString *authToken, *email;
	SEL entriesFinishedCallback;
	id collectionDelegate;
	BOOL stopped;
	SyncResponseFetcher *currentFetcher;
	
	id representedObject;
}

- (id)initWithEntriesToCollect:(NSArray*)wantedEntries authToken:(NSString*)anAuthToken email:(NSString*)anEmail;

- (NSArray*)entriesToCollect;
- (NSArray*)entriesCollected;
- (NSArray*)entriesInError;

- (void)stop;
- (BOOL)collectionStarted;

- (BOOL)collectionStoppedPrematurely;

- (NSString*)localizedActionDescription;

- (void)startCollectingWithCallback:(SEL)aSEL collectionDelegate:(id)aDelegate;

- (SyncResponseFetcher*)fetcherForEntry:(id)anEntry;

- (NSDictionary*)preparedDictionaryWithFetcher:(SyncResponseFetcher*)fetcher receivedData:(NSData*)data;

- (void)setRepresentedObject:(id)anObject;
- (id)representedObject;

@end

@interface SimplenoteEntryModifier : SimplenoteEntryCollector {
	SEL fetcherOpSEL;
}


- (id)initWithEntries:(NSArray*)wantedEntries operation:(SEL)opSEL authToken:(NSString*)anAuthToken email:(NSString*)anEmail;

- (SyncResponseFetcher*)_fetcherForNote:(NoteObject*)aNote creator:(BOOL)doesCreate;
- (SyncResponseFetcher*)fetcherForCreatingNote:(NoteObject*)aNote;
- (SyncResponseFetcher*)fetcherForUpdatingNote:(NoteObject*)aNote;
- (SyncResponseFetcher*)fetcherForDeletingNote:(DeletedNoteObject*)aDeletedNote;

@end
