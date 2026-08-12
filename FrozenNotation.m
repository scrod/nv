//
//  FrozenNotation.m
//  Notation
//
//  Created by Zachary Schneirov on 4/4/06.

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


#import "FrozenNotation.h"
#import "PassphraseRetriever.h"
#import "NSData_transformations.h"
#import "NotationPrefs.h"

static id UnarchiveObject(NSData *data, NSString *key, NSError **error) {
	NSError *unarchiveError = nil;
	NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&unarchiveError] autorelease];
	[unarchiver setRequiresSecureCoding:NO];
	id object = [unarchiver decodeTopLevelObjectForKey:key error:&unarchiveError];
	[unarchiver finishDecoding];
	if (error) *error = unarchiveError;
	return object;
}

@implementation FrozenNotation

- (id)initWithCoder:(NSCoder*)decoder {
	self = [super init];
	if (!self) return nil;
	if ([decoder containsValueForKey:VAR_STR(prefs)]) {
		prefs = [[decoder decodeObjectForKey:VAR_STR(prefs)] retain];
		notesData = [[decoder decodeObjectForKey:VAR_STR(notesData)] retain];
		deletedNoteSet = [[decoder decodeObjectForKey:VAR_STR(deletedNoteSet)] retain];
	} else {
		NSLog(@"FrozenNotation: decoding legacy %@", decoder);
		prefs = [[decoder decodeObject] retain];
		notesData = [[decoder decodeObject] retain];
		(void)[decoder decodeObject];
	}	
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	if ([coder allowsKeyedCoding]) {
		[coder encodeObject:prefs forKey:VAR_STR(prefs)];
		[coder encodeObject:notesData forKey:VAR_STR(notesData)];
		[coder encodeObject:deletedNoteSet forKey:VAR_STR(deletedNoteSet)];
	} else {
		[coder encodeObject:prefs];
		[coder encodeObject:notesData];
		[coder encodeObject:deletedNoteSet];
	}
}

- (id)initWithNotes:(NSMutableArray*)notes deletedNotes:(NSMutableSet*)antiNotes prefs:(NotationPrefs*)somePrefs {
	
	self = [super init];
	if (self) {

		NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
		[archiver encodeObject:notes forKey:@"notes"];
        [archiver finishEncoding];
		notesData = [[archiver encodedData] mutableCopy];
		[archiver release];
		
		prefs = [somePrefs retain];
		deletedNoteSet = [antiNotes retain];		
		
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
            NSLog(@"%@: empty notesData; returning nil", NSStringFromSelector(_cmd));
			return nil;
		}
	}
	
	return self;
}

- (void)dealloc {
	[allNotes release];
	[notesData release];
	[prefs release];
	[deletedNoteSet release];
	
	[super dealloc];
}

+ (NSData*)frozenDataWithExistingNotes:(NSMutableArray*)notes 
						  deletedNotes:(NSMutableSet*)antiNotes 
								 prefs:(NotationPrefs*)prefs {
	FrozenNotation *frozenNotation = [[FrozenNotation alloc] initWithNotes:notes deletedNotes:antiNotes prefs:prefs];

	if (!frozenNotation)
		return nil;
	
	NSError *archiveError = nil;
	NSData *encodedNotationData = [NSKeyedArchiver archivedDataWithRootObject:frozenNotation
		requiringSecureCoding:NO error:&archiveError];
	if (!encodedNotationData) NSLog(@"Error archiving notes and preferences: %@", archiveError);
	[frozenNotation autorelease];
	
	return encodedNotationData;
}

- (NSMutableArray*)unpackedNotesWithPrefs:(NotationPrefs*)somePrefs returningError:(OSStatus*)err {
	
	//decrypt notesData if necessary, then unarchive
	
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
		NSError *unarchiveError = nil;
		allNotes = [UnarchiveObject(notesData, @"notes", &unarchiveError) retain];
		if (!allNotes) {
			*err = kCoderErr;
			NSLog(@"(VERIFY) Error unarchiving notes from data: %@", unarchiveError);
			return nil;
		}
		
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
                NSError *unarchiveError = nil;
                allNotes = [UnarchiveObject(notesData, @"notes", &unarchiveError) retain];
                keyedArchiveFailed = allNotes == nil;
            } @catch (NSException *e) {
                keyedArchiveFailed = YES;
            }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (keyedArchiveFailed)
                allNotes = [[NSUnarchiver unarchiveObjectWithData:notesData] retain];
#pragma pop
		} @catch (NSException *e) {
			*err = kCoderErr;
			NSLog(@"Error unarchiving notes from data (%@, %@)", [e name], [e reason]);
			return(nil);
		}
	}
	
	return allNotes;
}

- (NSMutableSet*)deletedNotes {
	return deletedNoteSet;
}

- (NotationPrefs*)notationPrefs {
	return prefs;
}


@end
