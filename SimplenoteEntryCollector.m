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
#import "NSDictionary+BSJSONAdditions.h"
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
	NSURL *noteURL = [SimplenoteSession servletURLWithPath: [NSString stringWithFormat:@"/api2/data/%@", [entry objectForKey: @"key"]] parameters:
					  [NSDictionary dictionaryWithObjectsAndKeys: email, @"email", 
					   authToken, @"auth", nil]];
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
	
	NSDictionary *rawObject = nil;
	@try {
		rawObject = [NSDictionary dictionaryWithJSONString:bodyString];
	}
	@catch (NSException *e) {
		NSLog(@"Exception while parsing Simplenote JSON note object: %@", [e reason]);
	}
	@finally {
		if (!rawObject)
			return nil;
	}

	NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithCapacity:12];
	[entry setObject:[rawObject objectForKey:@"key"] forKey:@"key"];
	[entry setObject:[NSNumber numberWithInt:[[rawObject objectForKey:@"deleted"] intValue]] forKey:@"deleted"];
	// Normalize dates from unix epoch timestamps to mac os x epoch timestamps
	[entry setObject:[NSNumber numberWithDouble:[[NSDate dateWithTimeIntervalSince1970:[[rawObject objectForKey:@"createdate"] doubleValue]] timeIntervalSinceReferenceDate]] forKey:@"create"];
	[entry setObject:[NSNumber numberWithDouble:[[NSDate dateWithTimeIntervalSince1970:[[rawObject objectForKey:@"modifydate"] doubleValue]] timeIntervalSinceReferenceDate]] forKey:@"modify"];
	[entry setObject:[NSNumber numberWithInt:[[rawObject objectForKey:@"syncnum"] intValue]] forKey:@"syncnum"];
	[entry setObject:[NSNumber numberWithInt:[[rawObject objectForKey:@"version"] intValue]] forKey:@"version"];
	[entry setObject:[NSNumber numberWithInt:[[rawObject objectForKey:@"minversion"] intValue]] forKey:@"minversion"];
	if ([rawObject objectForKey:@"sharekey"]) {
		[entry setObject:[rawObject objectForKey:@"sharekey"] forKey:@"sharekey"];
	}
	if ([rawObject objectForKey:@"publishkey"]) {
		[entry setObject:[rawObject objectForKey:@"publishkey"] forKey:@"publishkey"];
	}
	[entry setObject:[rawObject objectForKey:@"systemtags"] forKey:@"systemtags"];
	[entry setObject:[rawObject objectForKey:@"tags"] forKey:@"tags"];
	if ([[fetcher representedObject] conformsToProtocol:@protocol(SynchronizedNote)]) [entry setObject:[fetcher representedObject] forKey:@"NoteObject"];
	[entry setObject:[rawObject objectForKey:@"content"] forKey:@"content"];

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
		NSDictionary *preparedDictionary = [self preparedDictionaryWithFetcher:fetcher receivedData:data];
		if (!preparedDictionary) {
			// Parsing JSON failed.  Is this the right way to handle the error?
			id obj = [fetcher representedObject];
			if (obj) {
				[entriesInError addObject: [NSDictionary dictionaryWithObjectsAndKeys: obj, @"NoteObject",
											[NSNumber numberWithInt:[fetcher statusCode]], @"StatusCode", nil]];
			}
		} else {
			[entriesCollected addObject: preparedDictionary];
		}
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
	NSDictionary *params = [NSDictionary dictionaryWithObjectsAndKeys: email, @"email", authToken, @"auth", nil];	
	
	NSMutableString *noteBody = [[[aNote combinedContentWithContextSeparator: /* explicitly assume default separator if creating */
								   doesCreate ? nil : [info objectForKey:SimplenoteSeparatorKey]] mutableCopy] autorelease];
	//simpletext iPhone app loses any tab characters
	[noteBody replaceTabsWithSpacesOfWidth:[[GlobalPrefs defaultPrefs] numberOfSpacesInTab]];
	
	NSMutableDictionary *rawObject = [NSMutableDictionary dictionaryWithCapacity: 12];
	if (modNum > 0.0) [rawObject setObject:[NSNumber numberWithDouble:[[NSDate dateWithTimeIntervalSinceReferenceDate:modNum] timeIntervalSince1970]] forKey:@"modifydate"];
	if (doesCreate) [rawObject setObject:[NSNumber numberWithDouble:[[NSDate dateWithTimeIntervalSinceReferenceDate:createdDateOfNote(aNote)] timeIntervalSince1970]] forKey:@"createdate"];
	
	NSArray *tags = [aNote orderedLabelTitles];
	// Don't send an empty tagset if this note has never been synced via sn-api2
	if ([tags count] || ([info objectForKey:@"syncnum"] != nil)) {
		[rawObject setObject:tags forKey:@"tags"];
	}
	
	[rawObject setObject:noteBody forKey:@"content"];

	NSURL *noteURL = nil;
	if (doesCreate) {
		noteURL = [SimplenoteSession servletURLWithPath:@"/api2/data" parameters:params];
	} else {
		noteURL = [SimplenoteSession servletURLWithPath:[NSString stringWithFormat:@"/api2/data/%@", [info objectForKey:@"key"]] parameters:params];
	}
	SyncResponseFetcher *fetcher = [[SyncResponseFetcher alloc] initWithURL:noteURL POSTData:[[rawObject jsonStringValue] dataUsingEncoding:NSUTF8StringEncoding] contentType:@"application/json" delegate:self];
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
	
	//in keeping with nv's behavior with sn api1, deleting only marks a note as deleted.
	//may want to implement actual purging (using HTTP DELETE) in the future
	NSURL *noteURL = [SimplenoteSession servletURLWithPath:[NSString stringWithFormat:@"/api2/data/%@", [info objectForKey:@"key"]] parameters:
					  [NSDictionary dictionaryWithObjectsAndKeys: email, @"email", 
					   authToken, @"auth", nil]];
	NSData *postData = [[[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:1] forKey:@"deleted"] jsonStringValue] dataUsingEncoding:NSUTF8StringEncoding];
	SyncResponseFetcher *fetcher = [[SyncResponseFetcher alloc] initWithURL:noteURL POSTData:postData contentType:@"application/json" delegate:self];
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
	
	NSString *bodyString = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	
	NSDictionary *rawObject = nil;
	@try {
		rawObject = [NSDictionary dictionaryWithJSONString:bodyString];
	}
	@catch (NSException *e) {
		NSLog(@"Exception while parsing Simplenote JSON note object: %@", [e reason]);
	}
	@finally {
		if (!rawObject)
			return nil;
	}
	
	NSString *keyString = [rawObject objectForKey:@"key"];
	
	NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:5];
	NSMutableDictionary *syncMD = [NSMutableDictionary dictionaryWithCapacity:5];
	[syncMD setObject:[rawObject objectForKey:@"key"] forKey:@"key"];
	[syncMD setObject:[NSNumber numberWithDouble:[[NSDate dateWithTimeIntervalSince1970:[[rawObject objectForKey:@"createdate"] doubleValue]] timeIntervalSinceReferenceDate]] forKey:@"create"];
	[syncMD setObject:[NSNumber numberWithDouble:[[NSDate dateWithTimeIntervalSince1970:[[rawObject objectForKey:@"modifydate"] doubleValue]] timeIntervalSinceReferenceDate]] forKey:@"modify"];
	[syncMD setObject:[NSNumber numberWithInt:[[rawObject objectForKey:@"syncnum"] intValue]] forKey:@"syncnum"];
	[syncMD setObject:[NSNumber numberWithBool:NO] forKey:@"dirty"];
	
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
			[aNote setSyncObjectAndKeyMD:syncMD forService:SimplenoteServiceName];

			[(NoteObject*)aNote makeNoteDirtyUpdateTime:NO updateFile:NO];
		} else if (@selector(fetcherForDeletingNote:) == fetcherOpSEL) {
			//this note has been successfully deleted, and can now have its Simplenote syncServiceMD entry removed 
			//so that _purgeAlreadyDistributedDeletedNotes can remove it permanently once the deletion has been synced with all other registered services
			NSAssert([aNote isKindOfClass:[DeletedNoteObject class]], @"received a non-deletednoteobject from a fetcherForDeletingNote: operation");
			[aNote removeAllSyncMDForService:SimplenoteServiceName];
		} else if (@selector(fetcherForUpdatingNote:) == fetcherOpSEL) {
			// SN api2 can return a content key in an update response containing
			// the merged changes from other clients....
			if ([rawObject objectForKey:@"content"]) {
				NSUInteger bodyLoc = 0;
				NSString *separator = nil;
				NSString *combinedContent = [rawObject objectForKey:@"content"];
				NSString *newTitle = [combinedContent syntheticTitleAndSeparatorWithContext:&separator bodyLoc:&bodyLoc oldTitle:titleOfNote(aNote) maxTitleLen:60];
				
				[(NoteObject *)aNote updateWithSyncBody:[combinedContent substringFromIndex:bodyLoc] andTitle:newTitle];
			}
			
			// Tags may have been changed by another client...
			NSSet *localTags = [NSSet setWithArray:[(NoteObject *)aNote orderedLabelTitles]];
			NSSet *remoteTags = [NSSet setWithArray:[rawObject objectForKey:@"tags"]];
			if (![localTags isEqualToSet:remoteTags]) {
				NSLog(@"Updating tags with remote values.");
				NSString *newLabelString = [[remoteTags allObjects] componentsJoinedByString:@" "];
				[(NoteObject *)aNote setLabelString:newLabelString];
			}

			[aNote setSyncObjectAndKeyMD:syncMD forService: SimplenoteServiceName];
			//NSLog(@"note update:\n %@", [aNote syncServicesMD]);
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
