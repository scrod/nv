//
//  SimplenoteEntryCollector.h
//  Notation
//
//  Created by Zachary Schneirov on 12/4/09.
//  Copyright 2009 Zachary Schneirov. All rights reserved.
//

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
