//
//  SimplenoteEntryCollector.m
//  Notation
//
//  Created by Zachary Schneirov on 12/4/09.

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


#import "GlobalPrefs.h"
#import "SimplenoteEntryCollector.h"
#import "SyncResponseFetcher.h"
#import "SimplenoteSession.h"
#import "NSString_NV.h"
#import "SynchronizedNoteProtocol.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"


@implementation SimplenoteEntryCollector

//instances this short-lived class are intended to be started only once, and then deallocated

- (id)initWithEntriesToCollect:(NSArray*)wantedEntries authToken:(NSString*)anAuthToken email:(NSString*)anEmail {
	if ([super init]) {
		authToken = [anAuthToken retain];
		email = [anEmail retain];
		entriesToCollect = [wantedEntries retain];
		entriesCollected = [[NSMutableArray alloc] init];
		entriesInError = [[NSMutableArray alloc] init];
		
		if (![email length] || ![authToken length] || ![entriesToCollect count]) {
			NSLog(@"%s: missing parameters", _cmd);
			return nil;
		}
	}
	return self;
}

- (NSArray*)entriesToCollect {
	return entriesToCollect;
}

- (NSArray*)entriesCollected {
	return entriesCollected;
}
- (NSArray*)entriesInError {
	return entriesInError;
}

- (BOOL)collectionStarted {
	return entryFinishedCount != 0;
}

- (BOOL)collectionStoppedPrematurely {
	return stopped;
}

- (void)setRepresentedObject:(id)anObject {
	[representedObject autorelease];
	representedObject = [anObject retain];
}

- (id)representedObject {
	return representedObject;
}

- (void)dealloc {
	[entriesCollected release];
	[entriesToCollect release];
	[entriesInError release];
	[representedObject release];
	[email release];
	[authToken release];
	[super dealloc];
}

- (NSString*)statusText {
	return [NSString stringWithFormat:NSLocalizedString(@"Downloading %u of %u notes", @"status text when downloading a note from the remote sync server"), 
			entryFinishedCount, [entriesToCollect count]];
}

- (SyncResponseFetcher*)currentFetcher {
	return currentFetcher;
}

- (NSString*)localizedActionDescription {
	return NSLocalizedString(@"Downloading", nil);
}

- (void)stop {
	stopped = YES;
	
	//cancel the current fetcher, which will cause it to send its finished callback
	//and the stopped condition will send this class' finished callback
	[currentFetcher cancel];
}

- (SyncResponseFetcher*)fetcherForEntry:(id)entry {
	
	id<SynchronizedNote>originalNote = nil;
	if ([entry conformsToProtocol:@protocol(SynchronizedNote)]) {
		originalNote = entry;
		entry = [[entry syncServicesMD] objectForKey:SimplenoteServiceName];
	}
	NSURL *noteURL = [SimplenoteSession servletURLWithPath:@"/api/note" parameters:
					  [NSDictionary dictionaryWithObjectsAndKeys: email, @"email", 
					   authToken, @"auth", [entry objectForKey:@"key"], @"key", nil]];
	SyncResponseFetcher *fetcher = [[SyncResponseFetcher alloc] initWithURL:noteURL POSTData:nil delegate:self];
	//remember the note for later? why not.
	if (originalNote) [fetcher setRepresentedObject:originalNote];
	return [fetcher autorelease];
}

- (void)startCollectingWithCallback:(SEL)aSEL collectionDelegate:(id)aDelegate {
	NSAssert([aDelegate respondsToSelector:aSEL], @"delegate doesn't respond!");
	NSAssert(![self collectionStarted], @"collection already started!");
	entriesFinishedCallback = aSEL;
	collectionDelegate = [aDelegate retain];
	
	[self retain];
	
	[(currentFetcher = [self fetcherForEntry:[entriesToCollect objectAtIndex:entryFinishedCount++]]) start];
}

- (NSDictionary*)preparedDictionaryWithFetcher:(SyncResponseFetcher*)fetcher receivedData:(NSData*)data {
	//logic abstracted for subclassing
	
	NSString *bodyString = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	NSDictionary *headers = [fetcher headers];
	
	NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithCapacity:5];
	[entry setObject:[headers objectForKey:@"Note-Key"] forKey:@"key"];
	[entry setObject:[NSNumber numberWithInt:[[headers objectForKey:@"Note-Deleted"] intValue]] forKey:@"deleted"];
	[entry setObject:[NSNumber numberWithDouble:[[headers objectForKey:@"Note-Createdate"] absoluteTimeFromSimplenoteDate]] forKey:@"create"];
	[entry setObject:[NSNumber numberWithDouble:[[headers objectForKey:@"Note-Modifydate"] absoluteTimeFromSimplenoteDate]] forKey:@"modify"];
	if ([[fetcher representedObject] conformsToProtocol:@protocol(SynchronizedNote)]) [entry setObject:[fetcher representedObject] forKey:@"NoteObject"];
	[entry setObject:bodyString forKey:@"content"];
	
	//NSLog(@"fetched entry %@" , entry);
	
	return entry;
}

- (void)syncResponseFetcher:(SyncResponseFetcher*)fetcher receivedData:(NSData*)data returningError:(NSString*)errString {
	
	if (errString) {
		NSLog(@"collector-%@ returned %@", fetcher, errString);
		id obj = [fetcher representedObject];
		if (obj) {
			[entriesInError addObject:[NSDictionary dictionaryWithObjectsAndKeys: obj, @"NoteObject", 
									   [NSNumber numberWithInt:[fetcher statusCode]], @"StatusCode", nil]];
		}
	} else {
		[entriesCollected addObject:[self preparedDictionaryWithFetcher:fetcher receivedData:data]];
	}
	
	if (entryFinishedCount >= [entriesToCollect count] || stopped) {
		//no more entries to collect!
		currentFetcher = nil;
		[collectionDelegate performSelector:entriesFinishedCallback withObject:self];
		[self autorelease];
		[collectionDelegate autorelease];
	} else {
		//queue next entry
		[(currentFetcher = [self fetcherForEntry:[entriesToCollect objectAtIndex:entryFinishedCount++]]) start];
	}
	
}

@end

@implementation SimplenoteEntryModifier

//TODO:
//if modification or creation date is 0, set it to the most recent time as parsed from the HTTP response headers
//when updating notes, sync times will be set to 0 when they are older than the time of the last HTTP header date
//which will be stored in notePrefs as part of the simplenote service dict

//all this to prevent syncing mishaps when notes are created and user's clock is set inappropriately

//modification times dates are set in case the app has been out of connectivity for a long time
//and to ensure we know what the time was for the next time we compare dates

- (id)initWithEntries:(NSArray*)wantedEntries operation:(SEL)opSEL authToken:(NSString*)anAuthToken email:(NSString*)anEmail {
	if ([super initWithEntriesToCollect:wantedEntries authToken:anAuthToken email:anEmail]) {
		//set creation and modification date when creating
		//set modification date when updating
		//need to check for success when deleting
		if (![self respondsToSelector:opSEL]) {
			NSLog(@"%@ doesn't respond to %s", self, opSEL);
			return nil;
		}
		fetcherOpSEL = opSEL;
	}
	return self;
}

- (SyncResponseFetcher*)fetcherForEntry:(id)anEntry {
	return [self performSelector:fetcherOpSEL withObject:anEntry];
}

- (SyncResponseFetcher*)_fetcherForNote:(NoteObject*)aNote creator:(BOOL)doesCreate {
	NSAssert([aNote isKindOfClass:[NoteObject class]], @"need a real note to create");
	
	//if we're creating a note, grab the metadata directly from the note object itself, as it will not have a syncServiceMD dict
	NSDictionary *info = [[aNote syncServicesMD] objectForKey:SimplenoteServiceName];
	//following assertion tests the efficacy our queued invocations system
	NSAssert(doesCreate == (nil == info), @"noteobject has MD for this service when it was attempting to be created or vise versa!");
	CFAbsoluteTime modNum = doesCreate ? modifiedDateOfNote(aNote) : [[info objectForKey:@"modify"] doubleValue];
	
	//always set the mod date, set created date if we are creating, set the key if we are updating
	NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObjectsAndKeys: email, @"email", authToken, @"auth", nil];	
	if (modNum > 0.0) [params setObject:[NSString simplenoteDateWithAbsoluteTime:modNum] forKey:@"modify"];
	if (doesCreate) [params setObject:[NSString simplenoteDateWithAbsoluteTime:createdDateOfNote(aNote)] forKey:@"create"];
	if (!doesCreate) [params setObject:[info objectForKey:@"key"] forKey:@"key"]; //raises its own exception if key is nil
	
	NSMutableString *noteBody = [[[aNote combinedContentWithContextSeparator: /* explicitly assume default separator if creating */
								   doesCreate ? nil : [info objectForKey:SimplenoteSeparatorKey]] mutableCopy] autorelease];
	//simpletext iPhone app loses any tab characters
	[noteBody replaceTabsWithSpacesOfWidth:[[GlobalPrefs defaultPrefs] numberOfSpacesInTab]];
	
	NSURL *noteURL = [SimplenoteSession servletURLWithPath:@"/api/note" parameters:params];
	SyncResponseFetcher *fetcher = [[SyncResponseFetcher alloc] initWithURL:noteURL bodyStringAsUTF8B64:noteBody delegate:self];
	[fetcher setRepresentedObject:aNote];
	return [fetcher autorelease];
}

- (SyncResponseFetcher*)fetcherForCreatingNote:(NoteObject*)aNote {
	return [self _fetcherForNote:aNote creator:YES];
}

- (SyncResponseFetcher*)fetcherForUpdatingNote:(NoteObject*)aNote {
	return [self _fetcherForNote:aNote creator:NO];
}

- (SyncResponseFetcher*)fetcherForDeletingNote:(DeletedNoteObject*)aDeletedNote {
	NSAssert([aDeletedNote isKindOfClass:[DeletedNoteObject class]], @"can't delete a note until you delete it yourself");
	
	NSDictionary *info = [[aDeletedNote syncServicesMD] objectForKey:SimplenoteServiceName];
	
	if (![info objectForKey:@"key"]) {
		//the deleted note lacks a key, so look up its created-equivalent and use _its_ metadata
		//handles the case of deleting a newly-created note after it had begun to sync, but before the remote operation gave it a key
		//because notes are queued against each other, by the time the create operation finishes on originalNote, it will have syncMD
		if ((info = [[[aDeletedNote originalNote] syncServicesMD] objectForKey:SimplenoteServiceName]))
			[aDeletedNote setSyncObjectAndKeyMD:info forService:SimplenoteServiceName];
	}
	NSAssert([info objectForKey:@"key"], @"fetcherForDeletingNote: got deleted note and couldn't find a key anywhere!");
	
	NSURL *noteURL = [SimplenoteSession servletURLWithPath:@"/api/delete" parameters:
					  [NSDictionary dictionaryWithObjectsAndKeys: email, @"email", 
					   authToken, @"auth", [info objectForKey:@"key"], @"key", nil]];
	SyncResponseFetcher *fetcher = [[SyncResponseFetcher alloc] initWithURL:noteURL POSTData:nil delegate:self];
	[fetcher setRepresentedObject:aDeletedNote];
	return [fetcher autorelease];
	
	return nil;
}

- (NSString*)localizedActionDescription {
	return (@selector(fetcherForCreatingNote:) == fetcherOpSEL ? NSLocalizedString(@"Creating", nil) :
			(@selector(fetcherForUpdatingNote:) == fetcherOpSEL ? NSLocalizedString(@"Updating",nil) : 
			 (@selector(fetcherForDeletingNote:) == fetcherOpSEL ? NSLocalizedString(@"Deleting", nil) : NSLocalizedString(@"Processing", nil)) ));
}

- (NSString*)statusText {
	NSString *opName = [self localizedActionDescription];
	if ([entriesToCollect count] == 1) {
		NoteObject *aNote = [currentFetcher representedObject];
		if ([aNote isKindOfClass:[NoteObject class]]) {
			return [NSString stringWithFormat:NSLocalizedString(@"%@ quot%@quot...",@"example: Updating 'joe shmoe note'"), opName, titleOfNote(aNote)];
		} else {
			return [NSString stringWithFormat:NSLocalizedString(@"%@ a note...", @"e.g., 'Deleting a note...'"), opName];
		}
	}
	return [NSString stringWithFormat:NSLocalizedString(@"%@ %u of %u notes", @"Downloading/Creating/Updating/Deleting 5 of 10 notes"), 
			opName, entryFinishedCount, [entriesToCollect count]];
}

#if 0 /* allowing creation to complete will be of no use when the note's 
	delegate notationcontroller has closed its WAL and DB, and as it is unretained can cause a crash */
- (void)stop {
	//cancel the current fetcher only if it is not a creator-fetcher; otherwise we risk it finishing without fully receiving notification of its sucess
	if (@selector(fetcherForCreatingNote:) == fetcherOpSEL) {
		//only stop the progression but allow the current fetcher to complete
		stopped = YES;
	} else {
		[super stop];
	}
}
#endif

- (NSDictionary*)preparedDictionaryWithFetcher:(SyncResponseFetcher*)fetcher receivedData:(NSData*)data {
	NSString *keyString = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	
	NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:5];
	if ([fetcher representedObject]) {
		id <SynchronizedNote> aNote = [fetcher representedObject];
		[result setObject:aNote forKey:@"NoteObject"];
		
		if (@selector(fetcherForCreatingNote:) == fetcherOpSEL) {
			//these entries were created because no metadata had existed, thus we must give them metadata now,
			//which SHOULD be the same metadata we used when creating the note, but in theory the note could have changed in the meantime
			//in that case the newer modification date should later cause a resynchronization
			
			//we are giving this note metadata immediately instead of waiting for the SimplenoteSession delegate to do it during the final callback
			//to reduce the possibility of duplicates in the case of interruptions (where we might have forgotten that we had already created this)
			
			NSAssert([aNote isKindOfClass:[NoteObject class]], @"received a non-noteobject from a fetcherForCreatingNote: operation!");
			//don't need to store a separator for newly-created notes; when nil it is presumed the default separator
			[aNote setSyncObjectAndKeyMD:[NSDictionary dictionaryWithObjectsAndKeys:
										  [NSNumber numberWithDouble:modifiedDateOfNote(aNote)], @"modify",
										  [NSNumber numberWithDouble:createdDateOfNote(aNote)], @"create",
										  keyString, @"key", nil] forService:SimplenoteServiceName];
			[(NoteObject*)aNote makeNoteDirtyUpdateTime:NO updateFile:NO];
		} else if (@selector(fetcherForDeletingNote:) == fetcherOpSEL) {
			//this note has been successfully deleted, and can now have its Simplenote syncServiceMD entry removed 
			//so that _purgeAlreadyDistributedDeletedNotes can remove it permanently once the deletion has been synced with all other registered services
			NSAssert([aNote isKindOfClass:[DeletedNoteObject class]], @"received a non-deletednoteobject from a fetcherForDeletingNote: operation");
			[aNote removeAllSyncMDForService:SimplenoteServiceName];
		} else if (@selector(fetcherForUpdatingNote:) == fetcherOpSEL) {
			
			//[aNote removeKey:@"dirty" forService:SimplenoteServiceName];
		} else {
			NSLog(@"%s called with unknown opSEL: %s", _cmd, fetcherOpSEL);
		}
		
	} else {
		NSLog(@"Hmmm. Fetcher %@ doesn't have a represented object. op = %s", fetcher, fetcherOpSEL);
	}
	[result setObject:keyString forKey:@"key"];
	
	
	return result;
}

@end
