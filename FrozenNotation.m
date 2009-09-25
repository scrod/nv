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
	if ([decoder containsValueForKey:VAR_STR(prefs)]) {
		prefs = [[decoder decodeObjectForKey:VAR_STR(prefs)] retain];
		notesData = [[decoder decodeObjectForKey:VAR_STR(notesData)] retain];
		deletedNotes = [[decoder decodeObjectForKey:VAR_STR(deletedNotes)] retain];		
	} else {		
		NSLog(@"FrozenNotation: decoding legacy %@", decoder);
		prefs = [[decoder decodeObject] retain];
		notesData = [[decoder decodeObject] retain];
		deletedNotes = [[decoder decodeObject] retain];
	}	
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	if ([coder allowsKeyedCoding]) {
		[coder encodeObject:prefs forKey:VAR_STR(prefs)];
		[coder encodeObject:notesData forKey:VAR_STR(notesData)];
		[coder encodeObject:deletedNotes forKey:VAR_STR(deletedNotes)];
	} else {
		[coder encodeObject:prefs];
		[coder encodeObject:notesData];
		[coder encodeObject:deletedNotes];
	}
}

- (id)initWithNotes:(NSMutableArray*)notes deletedNotes:(NSMutableArray*)antiNotes prefs:(NotationPrefs*)somePrefs {
	
	if ([super init]) {

		notesData = [[NSMutableData alloc] init];
		NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:notesData];
		[archiver encodeObject:notes forKey:@"notes"];
        [archiver finishEncoding];
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

- (NSMutableArray*)unpackedNotesWithPrefs:(NotationPrefs*)somePrefs returningError:(OSStatus*)err {
	
	//decrypt notesData, decrypting if necessary, then unarchive
	
	*err = noErr;
	
	@try {
		if ([somePrefs doesEncryption]) {
			if (![somePrefs decryptDataWithCurrentSettings:notesData]) {
				NSLog(@"Error decrypting data!");
				*err = kNoAuthErr;
				return nil;
			}
		}
		
		NSMutableData *oldNotesData = notesData;
		notesData = [[notesData uncompressedData] retain];
		[oldNotesData autorelease];
		
		if (!notesData) {
			*err = kCompressionErr;
			NSLog(@"Error decompressing data");
			return nil;
		}
		NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:notesData];
		allNotes = [[unarchiver decodeObjectForKey:@"notes"] retain];
		[unarchiver autorelease];
		
	} @catch (NSException *e) {
		*err = kCoderErr;
		NSLog(@"(VERIFY) Error unarchiving notes from data (%@, %@)", [e name], [e reason]);
		return nil;
	}
	
	return allNotes;
}


- (NSMutableArray*)unpackedNotesReturningError:(OSStatus*)err {
	
	//decrypt notesData, grabbing password from from keychain or user as necessary, then unarchive
	
	*err = noErr;
	
	if (!allNotes) {
		
		@try {
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
						return (nil);
					}
					//if result is 1, passphrase should already be loaded
				}
				if (![prefs decryptDataWithCurrentSettings:notesData]) {
					NSLog(@"Error decrypting data!");
					*err = kNoAuthErr;
					return(nil);
				}
			}
			
			//[notesData reverseBytes];
			
			NSMutableData *oldNotesData = notesData;
			notesData = [[notesData uncompressedData] retain];
			[oldNotesData autorelease];
			
			if (!notesData) {
				*err = kCompressionErr;
				NSLog(@"Error decompressing data");
				return(nil);
			}
            BOOL keyedArchiveFailed = NO;
            @try {
                NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:notesData];
                allNotes = [[unarchiver decodeObjectForKey:@"notes"] retain];
                [unarchiver autorelease];
            } @catch (NSException *e) {
                keyedArchiveFailed = YES;
            }
            
            if (keyedArchiveFailed)
                allNotes = [[NSUnarchiver unarchiveObjectWithData:notesData] retain];
		} @catch (NSException *e) {
			*err = kCoderErr;
			NSLog(@"Error unarchiving notes from data (%@, %@)", [e name], [e reason]);
			return(nil);
		}
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
