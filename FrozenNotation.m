//
//  FrozenNotation.m
//  Notation
//
//  Created by Zachary Schneirov on 4/4/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import "FrozenNotation.h"
#import "PassphraseRetriever.h"
#import "NSData_transformations.h"
#import "NotationPrefs.h"

@implementation FrozenNotation

- (id)initWithCoder:(NSCoder*)decoder {
	prefs = [[decoder decodeObject] retain];
	notesData = [[decoder decodeObject] retain];
	
	//do we really want nskeyedarchiver here?
	deletedNotes = [[decoder decodeObject] retain];
	
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	[coder encodeObject:prefs];
	[coder encodeObject:notesData];
	[coder encodeObject:deletedNotes];
}

- (id)initWithNotes:(NSMutableArray*)notes deletedNotes:(NSMutableArray*)antiNotes prefs:(NotationPrefs*)somePrefs {
	
	if ([super init]) {

		notesData = [[NSMutableData alloc] init];
#if USE_KEYED_ARCHIVING
		NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:notesData];
		[archiver encodeObject:notes forKey:@"notes"];
        [archiver finishEncoding];
#else
		NSArchiver *archiver = [[NSArchiver alloc] initForWritingWithMutableData:notesData];
		[archiver encodeRootObject:notes];
#endif
		[archiver release];
		
		prefs = [somePrefs retain];
		deletedNotes = [antiNotes retain];
		
		NSMutableData *oldNotesData = notesData;
		notesData = [[notesData compressedData] retain];
		[oldNotesData release];
		
		//ostensibly to create more entropy in the first blocks, relying on CBC dependency to crack
		//[notesData reverseBytes];
		
		if ([somePrefs doesEncryption]) {
			//compress?, reverse?, encrypt notesData based on notationprefs
			//we also want to have the salt reset here, but that requires knowing the original password
			
			if (![prefs encryptDataInNewSession:notesData]) {
				NSLog(@"Couldn't encrypt data!");
				return nil;
			}
		}
		
		if (![notesData length]) {
			[notesData release];
			return nil;
		}
	}
	
	return self;
}

- (void)dealloc {
	[allNotes release];
	[notesData release];
	[prefs release];
	[deletedNotes release];
	
	[super dealloc];
}

+ (NSData*)frozenDataWithExistingNotes:(NSMutableArray*)notes 
						  deletedNotes:(NSMutableArray*)antiNotes 
								 prefs:(NotationPrefs*)prefs {
	FrozenNotation *frozenNotation = [[FrozenNotation alloc] initWithNotes:notes deletedNotes:antiNotes prefs:prefs];

	if (!frozenNotation)
		return nil;
	
	NSData *encodedNotationData = [NSKeyedArchiver archivedDataWithRootObject:frozenNotation];
	[frozenNotation release];
	
	return encodedNotationData;
}

- (NSMutableArray*)unpackedNotesReturningError:(OSStatus*)err {
	
	//decrypt notesData, grabbing password from from keychain or user as necessary, then unarchive
	
	*err = noErr;
	
	if (!allNotes) {
		
		NS_DURING
			if ([prefs doesEncryption]) {
				BOOL keychainGood = YES;
				if (![prefs storesPasswordInKeychain] || !(keychainGood = [prefs canLoadPassphraseData:[prefs passwordDataFromKeychain]])) {
					
					if (!keychainGood) {
						//reset keychain identifier in case database file was duplicated and password was changed, and this is the old DB
						[prefs forgetKeychainIdentifier];
					}
					int result = [[PassphraseRetriever retrieverWithNotationPrefs:prefs] loadedUserPassphraseData];
					
					if (!result) {
						//must have clicked cancel or equivalent
						*err = kPassCanceledErr;
						NS_VALUERETURN(nil, NSMutableArray*);
					}
					//if result is 1, passphrase should already be loaded
				}
				if (![prefs decryptDataWithCurrentSettings:notesData]) {
					NSLog(@"Error decrypting data!");
					*err = kNoAuthErr;
					NS_VALUERETURN(nil, NSMutableArray*);
				}
			}
			
			//[notesData reverseBytes];
			
			NSMutableData *oldNotesData = notesData;
			notesData = [[notesData uncompressedData] retain];
			[oldNotesData autorelease];
			
			if (!notesData) {
				*err = kCompressionErr;
				NSLog(@"Error decompressing data");
				NS_VALUERETURN(nil, NSMutableArray*);
			}
#if USE_KEYED_ARCHIVING
			NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:notesData];
			allNotes = [[unarchiver decodeObjectForKey:@"notes"] retain];
			[unarchiver autorelease];
#else
			allNotes = [[NSUnarchiver unarchiveObjectWithData:notesData] retain];
#endif
		NS_HANDLER
			*err = kCoderErr;
			NSLog(@"Error unarchiving notes from data (%@, %@)", [localException name], [localException reason]);
			NS_VALUERETURN(nil, NSMutableArray*);
		NS_ENDHANDLER
	}
	
	return allNotes;
}

- (NSMutableArray*)deletedNotes {
	return deletedNotes;
}

- (NotationPrefs*)notationPrefs {
	return prefs;
}


@end
