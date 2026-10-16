//
//  NotationPrefs.m
//  Notation
//
//  Created by Zachary Schneirov on 4/1/06.

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


#import "NotationPrefs.h"
#import "NVRootedDirectory_Private.h"
#import "GlobalPrefs.h"
#import "NSString_NV.h"
#import "NSCollection_utils.h"
#import "NotationPrefsViewController.h"
#import "NSData_transformations.h"
#import "NotationDirectoryManager.h"
#import "SecureTextEntryManager.h"
#import <Security/Security.h>
#import <ApplicationServices/ApplicationServices.h>

#define DEFAULT_HASH_ITERATIONS 8000
#define DEFAULT_KEY_LENGTH 256

#define KEYCHAIN_SERVICENAME @"Notational Velocity"

#define INIT_DICT_ACCT() NSMutableDictionary *accountDict = ServiceAccountDictInit(self, serviceName)

NSString *NotationPrefsDidChangeNotification = @"NotationPrefsDidChangeNotification";

@interface NotationPrefs ()
@property (nonatomic, retain) NSData *masterSalt, *dataSessionSalt, *verifierKey, *masterKey;
@end

@implementation NotationPrefs

@synthesize preferencesChanged, foregroundColor, baseBodyFont,
	storesPasswordInKeychain, notesStorageFormat, confirmFileDeletion,
	doesEncryption, syncServiceAccounts, keyLengthInBits, hashIterationCount,
	epochIteration, firstTimeUsed, secureTextEntry, fileMetadataVolumeUUID, delegate,
	masterSalt, dataSessionSalt, verifierKey, masterKey;

NSMutableDictionary *ServiceAccountDictInit(NotationPrefs *prefs, NSString* serviceName) {
	NSMutableDictionary *accountDict = [prefs->syncServiceAccounts objectForKey:serviceName];
	if (!accountDict) [prefs->syncServiceAccounts setObject:(accountDict = [[NSMutableDictionary alloc] init]) forKey:serviceName];
	return accountDict;
}

+ (int)appVersion {
	return [[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"] intValue];
}

- (id)init {
    self = [super init];
    if (self) {
		unsigned int i;
		for (i=0; i<4; i++) {
			pathExtensions[i] = [[NotationPrefs defaultPathExtensionsForFormat:i] retain];
			chosenExtIndices[i] = 0;
		}
		
		confirmFileDeletion = YES;
		storesPasswordInKeychain = secureTextEntry = doesEncryption = NO;
		syncServiceAccounts = [[NSMutableDictionary alloc] init];
		notesStorageFormat = SingleDatabaseFormat;
		hashIterationCount = DEFAULT_HASH_ITERATIONS;
		keyLengthInBits = DEFAULT_KEY_LENGTH;
		baseBodyFont = [[[GlobalPrefs defaultPrefs] noteBodyFont] retain];
		foregroundColor = [[[GlobalPrefs defaultPrefs] foregroundTextColor] retain];
		epochIteration = 0;
		
		firstTimeUsed = preferencesChanged = YES;
		
    }
    return self;
}

- (id)initWithCoder:(NSCoder*)decoder {
    self = [super init];
    if (self) {
		NSAssert([decoder allowsKeyedCoding], @"Keyed decoding only!");
		
		//if we're initializing from an archive, we've obviously been run at least once before
		firstTimeUsed = NO;
		
		preferencesChanged = NO;
		
		epochIteration = [decoder decodeInt32ForKey:VAR_STR(epochIteration)];
		notesStorageFormat = [decoder decodeIntForKey:VAR_STR(notesStorageFormat)];
		doesEncryption = [decoder decodeBoolForKey:VAR_STR(doesEncryption)];
		storesPasswordInKeychain = [decoder decodeBoolForKey:VAR_STR(storesPasswordInKeychain)];
		secureTextEntry = [decoder decodeBoolForKey:VAR_STR(secureTextEntry)];
		
		if (!(hashIterationCount = [decoder decodeIntForKey:VAR_STR(hashIterationCount)]))
			hashIterationCount = DEFAULT_HASH_ITERATIONS;
		if (!(keyLengthInBits = [decoder decodeIntForKey:VAR_STR(keyLengthInBits)]))
			keyLengthInBits = DEFAULT_KEY_LENGTH;
		
		@try {
			baseBodyFont = [[decoder decodeObjectForKey:VAR_STR(baseBodyFont)] retain];
		} @catch (NSException *e) {
			NSLog(@"Error trying to unarchive default base body font (%@, %@)", [e name], [e reason]);
		}
		if (!baseBodyFont || ![baseBodyFont isKindOfClass:[NSFont class]]) {
			baseBodyFont = [[[GlobalPrefs defaultPrefs] noteBodyFont] retain];
			NSLog(@"setting base body to current default: %@", baseBodyFont);
			preferencesChanged = YES;
		}
		//foregroundColor does not receive the same treatment as basebodyfont; in the event of a discrepancy between global and per-db settings,
		//the former is applied to the notes in the database, while the latter is restored from the database itself
		@try {
			foregroundColor = [[decoder decodeObjectForKey:VAR_STR(foregroundColor)] retain];
		} @catch (NSException *e) {
			NSLog(@"Error trying to unarchive foreground text color (%@, %@)", [e name], [e reason]);
		}
		if (!foregroundColor || ![foregroundColor isKindOfClass:[NSColor class]]) {
			foregroundColor = [[[GlobalPrefs defaultPrefs] foregroundTextColor] retain];
			preferencesChanged = YES;
		}
		
		confirmFileDeletion = [decoder decodeBoolForKey:VAR_STR(confirmFileDeletion)];
		
		unsigned int i;
		for (i=0; i<4; i++) {
			if (!(pathExtensions[i] = [[decoder decodeObjectForKey:[VAR_STR(pathExtensions) stringByAppendingFormat:@".%d",i]] retain]))
				pathExtensions[i] = [[NotationPrefs defaultPathExtensionsForFormat:i] retain];
			chosenExtIndices[i] = [decoder decodeIntForKey:[VAR_STR(chosenExtIndices) stringByAppendingFormat:@".%d",i]];
		}
		
		if (!(syncServiceAccounts = [[decoder decodeObjectForKey:VAR_STR(syncServiceAccounts)] retain]))
			syncServiceAccounts = [[NSMutableDictionary alloc] init];
		keychainDatabaseIdentifier = [[decoder decodeObjectForKey:VAR_STR(keychainDatabaseIdentifier)] retain];
		
		fileMetadataVolumeUUID = [[decoder decodeObjectForKey:@"fileMetadataVolumeUUID"] retain];
		
		masterSalt = [[decoder decodeObjectForKey:VAR_STR(masterSalt)] retain];
		dataSessionSalt = [[decoder decodeObjectForKey:VAR_STR(dataSessionSalt)] retain];
		verifierKey = [[decoder decodeObjectForKey:VAR_STR(verifierKey)] retain];
		
		doesEncryption = doesEncryption && verifierKey && masterSalt;
		
    }
	
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	NSAssert([coder allowsKeyedCoding], @"Keyed encoding only!");
	
	/* epochIteration:
	 0: .Blor files
	 1: First NSArchiver (was unused--maps to 0)
	 2: First NSKeyedArchiver
	 3: First syncServicesMD and date created/modified syncing to files
	 4: tracking of file size and attribute mod dates, font foreground colors, openmeta labels
	 5: APFS document identifiers and nanosecond file metadata
	 */
	[coder encodeInt32:EPOC_ITERATION forKey:VAR_STR(epochIteration)];
	
	[coder encodeInt:notesStorageFormat forKey:VAR_STR(notesStorageFormat)];
	[coder encodeBool:doesEncryption forKey:VAR_STR(doesEncryption)];
	[coder encodeBool:storesPasswordInKeychain forKey:VAR_STR(storesPasswordInKeychain)];
	[coder encodeInt:hashIterationCount forKey:VAR_STR(hashIterationCount)];
	[coder encodeInt:keyLengthInBits forKey:VAR_STR(keyLengthInBits)];
	[coder encodeBool:secureTextEntry forKey:VAR_STR(secureTextEntry)];
	
	[coder encodeBool:confirmFileDeletion forKey:VAR_STR(confirmFileDeletion)];
	[coder encodeObject:baseBodyFont forKey:VAR_STR(baseBodyFont)];
	[coder encodeObject:foregroundColor forKey:VAR_STR(foregroundColor)];
	
	unsigned int i;
	for (i=0; i<4; i++) {	
		[coder encodeObject:pathExtensions[i] forKey:[VAR_STR(pathExtensions) stringByAppendingFormat:@".%d",i]];
		[coder encodeInt:chosenExtIndices[i] forKey:[VAR_STR(chosenExtIndices) stringByAppendingFormat:@".%d",i]];
	}
	
	[coder encodeObject:[self syncServiceAccountsForArchiving] forKey:VAR_STR(syncServiceAccounts)];
	
	[coder encodeObject:keychainDatabaseIdentifier forKey:VAR_STR(keychainDatabaseIdentifier)];
	
	[coder encodeObject:fileMetadataVolumeUUID forKey:@"fileMetadataVolumeUUID"];
	
	[coder encodeObject:masterSalt forKey:VAR_STR(masterSalt)];
	[coder encodeObject:dataSessionSalt forKey:VAR_STR(dataSessionSalt)];
	[coder encodeObject:verifierKey forKey:VAR_STR(verifierKey)];
}


- (void)dealloc {
    
    unsigned int i;
    for (i=0; i<4; i++) {
	[pathExtensions[i] release];
    }
	
	[syncServiceAccounts release];
	[fileMetadataVolumeUUID release];
	[keychainDatabaseIdentifier release];
	[baseBodyFont release];
	[foregroundColor release];
	[masterSalt release];
	[dataSessionSalt release];
	[verifierKey release];
	[masterKey release];
    
    [super dealloc];
}

+ (NSMutableArray*)defaultPathExtensionsForFormat:(int)formatID {
    switch (formatID) {
	case SingleDatabaseFormat:
	    return [NSMutableArray arrayWithCapacity:0];
	case PlainTextFormat: 
	    return [NSMutableArray arrayWithObjects:@"txt", @"text", @"md", @"utf8", @"taskpaper", nil];
	case RTFTextFormat: 
	    return [NSMutableArray arrayWithObjects:@"rtf", nil];
	case HTMLFormat:
	    return [NSMutableArray arrayWithObjects:@"html", @"htm", nil];
	case WordDocFormat:
		return [NSMutableArray arrayWithObjects:@"doc", nil];
	case WordXMLFormat:
		return [NSMutableArray arrayWithObjects:@"docx", nil];
	default:
	    NSLog(@"Unknown format ID: %d", formatID);
    }
    
    return [NSMutableArray arrayWithCapacity:0];
}

- (NSDictionary*)syncAccountForServiceName:(NSString*)serviceName {
	return [syncServiceAccounts objectForKey:serviceName];
}

- (NSDictionary *)_keychainQueryForAccount:(NSString *)account {
	return [NSDictionary dictionaryWithObjectsAndKeys:
		(id)kSecClassGenericPassword, (id)kSecClass,
		KEYCHAIN_SERVICENAME, (id)kSecAttrService,
		account, (id)kSecAttrAccount,
		nil];
}

- (NSData *)_keychainDataForAccount:(NSString *)account status:(OSStatus *)status {
	NSMutableDictionary *query = [NSMutableDictionary dictionaryWithDictionary:[self _keychainQueryForAccount:account]];
	[query setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnData];
	[query setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];

	CFTypeRef result = NULL;
	*status = SecItemCopyMatching((CFDictionaryRef)query, &result);
	return *status == noErr ? [(NSData *)result autorelease] : nil;
}

- (SecKeychainItemRef)_keychainItemForAccount:(NSString *)account {
	NSMutableDictionary *query = [NSMutableDictionary dictionaryWithDictionary:[self _keychainQueryForAccount:account]];
	[query setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnRef];
	[query setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];

	CFTypeRef result = NULL;
	return SecItemCopyMatching((CFDictionaryRef)query, &result) == noErr ? (SecKeychainItemRef)result : NULL;
}

- (NSDictionary *)_keychainQueryForFirstItemInAccount:(NSString *)account {
	SecKeychainItemRef item = [self _keychainItemForAccount:account];
	if (!item) return nil;

	NSMutableDictionary *query = [NSMutableDictionary dictionaryWithDictionary:[self _keychainQueryForAccount:account]];
	[query setObject:@[ (id)item ] forKey:(id)kSecMatchItemList];
	CFRelease(item);
	return query;
}

- (OSStatus)_setKeychainData:(NSData *)data forAccount:(NSString *)account {
	NSDictionary *query = [self _keychainQueryForFirstItemInAccount:account];
	NSDictionary *attributes = @{ (id)kSecValueData: data };
	OSStatus status = query ? SecItemUpdate((CFDictionaryRef)query, (CFDictionaryRef)attributes) : errSecItemNotFound;
	if (!query) {
		NSMutableDictionary *newItem = [NSMutableDictionary dictionaryWithDictionary:[self _keychainQueryForAccount:account]];
		[newItem setObject:data forKey:(id)kSecValueData];
		status = SecItemAdd((CFDictionaryRef)newItem, NULL);
	}
	return status;
}

- (OSStatus)_removeKeychainDataForAccount:(NSString *)account {
	NSDictionary *query = [self _keychainQueryForFirstItemInAccount:account];
	return query ? SecItemDelete((CFDictionaryRef)query) : errSecItemNotFound;
}

- (NSString*)syncPasswordForServiceName:(NSString*)serviceName {
	//if non-existing, fetch from keychain and cache
	
	INIT_DICT_ACCT();
	
	NSString *password = [accountDict objectForKey:@"password"];
	if (password) return password;
	
	const char *kcSyncAccountName = [self keychainSyncAccountNameForService:serviceName];
	if (!kcSyncAccountName) return nil;

	OSStatus err;
	NSData *passwordData = [self _keychainDataForAccount:[NSString stringWithUTF8String:kcSyncAccountName] status:&err];
	if (err != noErr) {
		NSLog(@"Error finding keychain password for service account %@: %d\n", serviceName, (int)err);
		return nil;
	}
	password = [[[NSString alloc] initWithData:passwordData encoding:NSUTF8StringEncoding] autorelease];
	
	//cache password found in keychain
	[accountDict setObject:password forKey:@"password"];
	return password;
}

- (NSDictionary*)syncServiceAccountsForArchiving {
	NSMutableDictionary *tempDict = [[syncServiceAccounts mutableCopy] autorelease];
	
	NSEnumerator *enumerator = [tempDict objectEnumerator];
	NSMutableDictionary *account = nil;
	while ((account = [enumerator nextObject])) {
		
		if (![(NSString*)[account objectForKey:@"username"] length]) {
			//don't store the "enabled" flag if the account has no username
			//give password the benefit of the doubt as it may eventually become available via the keychain
			[account removeObjectForKey:@"enabled"];
		}
		[account removeObjectForKey:@"password"];
	}
	return tempDict;
}

- (BOOL)syncNotesShouldMergeForServiceName:(NSString*)serviceName {
	NSDictionary *accountDict = [self syncAccountForServiceName:serviceName];
	NSString *username = [accountDict objectForKey:@"username"];
	return username && [[accountDict objectForKey:@"shouldmerge"] isEqualToString:username];
}

- (NSUInteger)syncFrequencyInMinutesForServiceName:(NSString*)serviceName {
	NSUInteger freq = MIN([[[self syncAccountForServiceName:serviceName] objectForKey:@"frequency"] unsignedIntValue], 30U);
	return freq == 0 ? 5 : freq;
}

- (BOOL)syncServiceIsEnabled:(NSString*)serviceName {
	return [[[self syncAccountForServiceName:serviceName] objectForKey:@"enabled"] boolValue];
}

- (void)setPreferencesAreStored {
	preferencesChanged = NO;
}

- (void)setForegroundTextColor:(NSColor*)aColor {
	[foregroundColor autorelease];
	foregroundColor = [aColor retain];
	
	preferencesChanged = YES;
}

- (void)setBaseBodyFont:(NSFont*)aFont {
	[baseBodyFont autorelease];
	baseBodyFont = [aFont retain];
		
	preferencesChanged = YES;
}

- (void)forgetKeychainIdentifier {
	
	[keychainDatabaseIdentifier release];
	keychainDatabaseIdentifier = nil;
	
	preferencesChanged = YES;
}

- (const char *)setKeychainIdentifier {
	if (!keychainDatabaseIdentifier) {
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		keychainDatabaseIdentifier = (NSString*)CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
		CFRelease(uuidRef);

		preferencesChanged = YES;
	}
	
	return [keychainDatabaseIdentifier UTF8String];
}

- (SecKeychainItemRef)currentKeychainItem {
	return [self _keychainItemForAccount:[NSString stringWithUTF8String:[self setKeychainIdentifier]]];
}

- (void)removeKeychainData {
	OSStatus err = [self _removeKeychainDataForAccount:[NSString stringWithUTF8String:[self setKeychainIdentifier]]];
	if (err != noErr && err != errSecItemNotFound)
		NSLog(@"Error deleting keychain item: %d", (int)err);
}

- (NSData*)passwordDataFromKeychain {
	const char *accountName = [self setKeychainIdentifier];
	OSStatus err;
	NSData *data = [self _keychainDataForAccount:[NSString stringWithUTF8String:accountName] status:&err];
	if (err != noErr) {
		NSLog(@"Error finding keychain password for account %s: %d\n", accountName, (int)err);
		return nil;
	}
	return data;
}

- (void)setKeychainData:(NSData*)data {
	OSStatus status = [self _setKeychainData:data forAccount:[NSString stringWithUTF8String:[self setKeychainIdentifier]]];
	if (status != noErr)
		NSLog(@"Error storing passphrase item in keychain: %d", status);
}

- (void)setStoresPasswordInKeychain:(BOOL)value {
	storesPasswordInKeychain = value;
	preferencesChanged = YES;
	
	if (!storesPasswordInKeychain)
		[self removeKeychainData];
}

- (BOOL)_masterKeyMatchesVerifier:(NSData*)candidateMasterKey {
	//compute verify key given "verify" salt and 1 iteration, then check against verify key data
	NSData *verifySalt = [NSData dataWithBytesNoCopy:VERIFY_SALT length:sizeof(VERIFY_SALT) freeWhenDone:NO];
	NSData *computedVerifyKey = [candidateMasterKey derivedKeyOfLength:keyLengthInBits/8 salt:verifySalt iterations:1];
	return [computedVerifyKey isEqualToData:verifierKey];
}

- (BOOL)hasMasterKey {
	return masterKey != nil;
}

- (BOOL)loadMasterKeyFromUnlockedPrefs:(NotationPrefs*)unlockedPrefs {
	/* Startup recovery reopens the database in a second controller.  Its freshly
	 * decoded prefs adopt the key unlocked by the first controller when that key
	 * matches this database's verifier, along with the keychain choice made while
	 * unlocking it, so the user enters the passphrase once per launch. */
	NSData *unlockedKey = unlockedPrefs ? unlockedPrefs->masterKey : nil;
	if (!doesEncryption || masterKey || !unlockedKey || ![self _masterKeyMatchesVerifier:unlockedKey])
		return NO;

	self.masterKey = unlockedKey;

	NSString *unlockedIdentifier = unlockedPrefs->keychainDatabaseIdentifier;
	if (storesPasswordInKeychain != unlockedPrefs->storesPasswordInKeychain ||
		(keychainDatabaseIdentifier != unlockedIdentifier &&
		 ![keychainDatabaseIdentifier isEqualToString:unlockedIdentifier])) {
		storesPasswordInKeychain = unlockedPrefs->storesPasswordInKeychain;
		[keychainDatabaseIdentifier autorelease];
		keychainDatabaseIdentifier = [unlockedIdentifier copy];
		preferencesChanged = YES;
	}
	return YES;
}

- (NSData*)derivedMasterKeyCandidateFromPassphraseData:(NSData*)passData {
	/* Computes a candidate master key given the stored salt and the iteration count calibrated (see
	 * KeyDerivationManager) as a deliberate, possibly multi-second brute-force-resistance cost factor. This
	 * reads only this instance's immutable salt/iteration/length state and mutates nothing, so unlike
	 * -canLoadPassphraseData:, it is safe to call from a background queue; apply its result on the main
	 * thread afterward with -acceptMasterKeyIfValid:. */
	return [passData derivedKeyOfLength:keyLengthInBits/8 salt:masterSalt iterations:hashIterationCount];
}

- (BOOL)acceptMasterKeyIfValid:(NSData*)candidateMasterKey {
	/* Call on the main thread with a key already derived by -derivedMasterKeyCandidateFromPassphraseData:. */
	if (![self _masterKeyMatchesVerifier:candidateMasterKey])
		return NO;

	//if candidateMasterKey is good, and we don't already have a master key, then this is it
	if (!masterKey)
		self.masterKey = candidateMasterKey;

	return YES;
}

- (BOOL)canLoadPassphraseData:(NSData*)passData {
	return [self acceptMasterKeyIfValid:[self derivedMasterKeyCandidateFromPassphraseData:passData]];
}

- (BOOL)canLoadPassphrase:(NSString*)pass {
	return [self canLoadPassphraseData:[pass dataUsingEncoding:NSUTF8StringEncoding]];
}

- (BOOL)encryptDataInNewSession:(NSMutableData*)data {
	//ideally we would vary AES algo between 128 and 256 bits depending on key length, 
	//and scale beyond with triplets, quintuplets, and septuplets--but key is not currently user-settable

	//create new dataSessionSalt and key here
	self.dataSessionSalt = [NSData randomDataOfLength:256];
	
	NSData *dataSessionKey = [masterKey derivedKeyOfLength:keyLengthInBits/8 salt:dataSessionSalt iterations:1];
	
	return [data encryptAESDataWithKey:dataSessionKey iv:[dataSessionSalt subdataWithRange:NSMakeRange(0, 16)]];
}
- (BOOL)decryptDataWithCurrentSettings:(NSMutableData*)data {
	
	NSData *dataSessionKey = [masterKey derivedKeyOfLength:keyLengthInBits/8 salt:dataSessionSalt iterations:1];
	
	return [data decryptAESDataWithKey:dataSessionKey iv:[dataSessionSalt subdataWithRange:NSMakeRange(0, 16)]];
}

- (void)setPassphraseData:(NSData*)passData inKeychain:(BOOL)inKeychain {
	[self setPassphraseData:passData inKeychain:inKeychain withIterations:hashIterationCount];
}

- (void)setPassphraseData:(NSData*)passData inKeychain:(BOOL)inKeychain withIterations:(int)iterationCount {
	
	hashIterationCount = iterationCount;
	int keyLength = keyLengthInBits/8;
	
	//generate and set random salt
	self.masterSalt = [NSData randomDataOfLength:256];

	//compute and set master key given salt and # of iterations
	self.masterKey = [passData derivedKeyOfLength:keyLength salt:masterSalt iterations:hashIterationCount];
	
	//compute and set verify key from master key
	NSData *verifySalt = [NSData dataWithBytesNoCopy:VERIFY_SALT length:sizeof(VERIFY_SALT) freeWhenDone:NO];
	self.verifierKey = [masterKey derivedKeyOfLength:keyLength salt:verifySalt iterations:1];

	//update keychain
	[self setStoresPasswordInKeychain:inKeychain];
	if (inKeychain)
		[self setKeychainData:passData];
	
	preferencesChanged = YES;
	
	if ([delegate respondsToSelector:@selector(databaseEncryptionSettingsChanged)])
		[delegate databaseEncryptionSettingsChanged];
}

- (NSData*)WALSessionKey {
	#define CONST_WAL_KEY "This is a 32 byte temporary key"
	NSData *sessionSalt = [NSData dataWithBytesNoCopy:LOG_SESSION_SALT length:sizeof(LOG_SESSION_SALT) freeWhenDone:NO];
	
	if (!doesEncryption)
		return [NSData dataWithBytesNoCopy:CONST_WAL_KEY length:sizeof(CONST_WAL_KEY) freeWhenDone:NO];

	return [masterKey derivedKeyOfLength:keyLengthInBits/8 salt:sessionSalt iterations:1];
}

- (void)setNotesStorageFormat:(int)formatID {
	if (formatID != notesStorageFormat) {
		if ([delegate respondsToSelector:@selector(flushAllNoteChanges)] &&
			![delegate flushAllNoteChanges]) return;
		if (notesStorageFormat != SingleDatabaseFormat &&
			[delegate respondsToSelector:@selector(synchronizeNotesFromDirectory)] &&
			![delegate synchronizeNotesFromDirectory]) return;

		int oldFormat = notesStorageFormat;
		notesStorageFormat = formatID;	
		preferencesChanged = YES;
		
		if ([delegate respondsToSelector:@selector(databaseSettingsChangedFromOldFormat:)])
			[delegate databaseSettingsChangedFromOldFormat:oldFormat];
		
		//should notationprefs need to do this?
		if ([delegate respondsToSelector:@selector(flushEverything)])
			[delegate flushEverything];
	}
}

- (BOOL)shouldDisplaySheetForProposedFormat:(int)proposedFormat {
	BOOL notesExist = YES;
	
	if ([delegate respondsToSelector:@selector(totalNoteCount)])
		notesExist = [delegate totalNoteCount] > 0;

	return (proposedFormat == SingleDatabaseFormat && notesStorageFormat != SingleDatabaseFormat && notesExist);
}

- (void)noteFilesCleanupSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	
	NSAssert(contextInfo, @"No contextInfo passed to noteFilesCleanupSheetDidEnd");
	NSAssert([(id)contextInfo respondsToSelector:@selector(notesStorageFormatInProgress)],
			 @"can't get notesStorageFormatInProgress method for changing");

	int newNoteStorageFormat = [(NotationPrefsViewController*)contextInfo notesStorageFormatInProgress];
	
	if (returnCode != NSAlertSecondButtonReturn)
		//didn't cancel
		[self setNotesStorageFormat:newNoteStorageFormat];
	BOOL formatChanged = notesStorageFormat == newNoteStorageFormat;
	
	if (returnCode == NSAlertThirdButtonReturn && formatChanged)
		//tell delegate to delete all its notes' files
		[delegate trashRemainingNoteFilesInDirectory];
	//but what if the files remain after switching to a single-db format--and then the user deletes a bunch of the files themselves?
	//should we switch the currentFormatIDs of those notes to single-db? I guess.
	
	if ([(id)contextInfo respondsToSelector:@selector(notesStorageFormatDidChange)])
		[(NotationPrefsViewController*)contextInfo notesStorageFormatDidChange];
	
	if (returnCode != NSAlertSecondButtonReturn && formatChanged) {
		//run queued method
		NSAssert([(id)contextInfo respondsToSelector:@selector(runQueuedStorageFormatChangeInvocation)],
				 @"can't get runQueuedStorageFormatChangeInvocation method for changing");

		[(NotationPrefsViewController*)contextInfo runQueuedStorageFormatChangeInvocation];
	}
}

- (void)setConfirmsFileDeletion:(BOOL)value {
    confirmFileDeletion = value;
    preferencesChanged = YES;
}

- (void)setDoesEncryption:(BOOL)value {
	BOOL oldValue = doesEncryption;
	doesEncryption = value;
	
	preferencesChanged = YES;

	if (!doesEncryption) {
		[self removeKeychainData];
	
		//clear out the verifier key and salt?
		self.verifierKey = nil;
		self.masterKey = nil;
	}
	
	if (oldValue != value) {
		if ([delegate respondsToSelector:@selector(databaseEncryptionSettingsChanged)])
			[delegate databaseEncryptionSettingsChanged];
	}
}

- (void)setSecureTextEntry:(BOOL)value {
	
	secureTextEntry = value;
	
	preferencesChanged = YES;
	
	SecureTextEntryManager *tem = [SecureTextEntryManager sharedInstance];
	
	if (secureTextEntry) {
		[tem enableSecureTextEntry];
		[tem checkForIncompatibleApps];
	} else {
		//"forget" that the user had disabled the warning dialog when disabling this feature permanently
		[[NSUserDefaults standardUserDefaults] removeObjectForKey:ShouldHideSecureTextEntryWarningKey];
		[tem disableSecureTextEntry];
	}
}

- (void)setSyncEnabled:(BOOL)isEnabled forService:(NSString*)serviceName {
	INIT_DICT_ACCT();
	
	if ([self syncServiceIsEnabled:serviceName] != isEnabled) {
		[accountDict setObject:@(isEnabled) forKey:@"enabled"];
		
		preferencesChanged = YES;
		[delegate syncSettingsChangedForService:serviceName];
	}
}

- (void)setSyncFrequency:(NSUInteger)frequencyInMinutes forService:(NSString*)serviceName {
	INIT_DICT_ACCT();
	
	if ([self syncFrequencyInMinutesForServiceName:serviceName] != frequencyInMinutes) {
		[accountDict setObject:@(frequencyInMinutes) forKey:@"frequency"];
		preferencesChanged = YES;
		[delegate syncSettingsChangedForService:serviceName];
	}
}

- (void)setSyncShouldMerge:(BOOL)shouldMerge inCurrentAccountForService:(NSString*)serviceName {
	INIT_DICT_ACCT();
	
	if ([self syncNotesShouldMergeForServiceName:serviceName] != shouldMerge) {
		NSString *username = [accountDict objectForKey:@"username"];
		if (username) {
			NSLog(@"%@: %d, %@", NSStringFromSelector(_cmd), shouldMerge, username);
			if (shouldMerge) {
				[accountDict setObject:username forKey:@"shouldmerge"];
			} else {
				[accountDict removeObjectForKey:@"shouldmerge"];
			}
			preferencesChanged = YES;
		} else {
			NSLog(@"%@: no username found in %@", NSStringFromSelector(_cmd), serviceName);
		}
	}
}

- (void)setSyncUsername:(NSString*)username forService:(NSString*)serviceName {
	
	INIT_DICT_ACCT();
	
	if (![[accountDict objectForKey:@"username"] isEqualToString:username]) {
		[accountDict setObject:username forKey:@"username"];
		
		preferencesChanged = YES;
		[delegate syncSettingsChangedForService:serviceName];
	}
}

- (const char*)keychainSyncAccountNameForService:(NSString*)serviceName {
	NSString *username = [[self syncAccountForServiceName:serviceName] objectForKey:@"username"];
	return [username length] ? [[username stringByAppendingFormat:@"-%@", serviceName] UTF8String] : NULL;
}

- (void)setSyncPassword:(NSString*)password forService:(NSString*)serviceName {
	//a username _MUST_ already exist in the account dict in order for the password to be saved in the keychain
	
	INIT_DICT_ACCT();
	
	if (![[accountDict objectForKey:@"password"] isEqualToString:password]) {
		[accountDict setObject:password forKey:@"password"];
		
		NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding];
		
		const char *kcSyncAccountName = [self keychainSyncAccountNameForService:serviceName];
		if (kcSyncAccountName) {
			OSStatus status = [self _setKeychainData:passwordData forAccount:[NSString stringWithUTF8String:kcSyncAccountName]];
			if (status != noErr)
				NSLog(@"Error storing service password in keychain: %d", status);
		} else {
			NSLog(@"not storing password in keychain for %@ because a sync account name couldn't be created", serviceName);
		}
			
		preferencesChanged = YES;
		[delegate syncSettingsChangedForService:serviceName];
	}
}

- (void)removeSyncPasswordForService:(NSString*)serviceName {
	INIT_DICT_ACCT();
	
	if ([accountDict objectForKey:@"password"]) {
		[accountDict removeObjectForKey:@"password"];
		
		const char *kcSyncAccountName = [self keychainSyncAccountNameForService:serviceName];
		if (kcSyncAccountName) {
			OSStatus err = [self _removeKeychainDataForAccount:[NSString stringWithUTF8String:kcSyncAccountName]];
			if (err != noErr && err != errSecItemNotFound)
				NSLog(@"Error deleting keychain item for service %@: %d", serviceName, (int)err);
		} else {
			NSLog(@"not removing password for %@ because a keychain sync account name couldn't be created", serviceName);
		}
		
		[delegate syncSettingsChangedForService:serviceName];
	}
}

- (void)setFileMetadataVolumeUUID:(NSString*)volumeUUID {
	if (fileMetadataVolumeUUID == volumeUUID || [fileMetadataVolumeUUID isEqualToString:volumeUUID]) return;
	[fileMetadataVolumeUUID release];
	fileMetadataVolumeUUID = [volumeUUID copy];
	preferencesChanged = YES;
}

- (void)setKeyLengthInBits:(unsigned int)newLength {
	//can't do this because we don't have password string
    /*keyLengthInBits = newLength;
    preferencesChanged = YES;
    */
}

+ (NSString*)pathExtensionForFormat:(int)format {
    switch (format) {
	case SingleDatabaseFormat:
	case PlainTextFormat:
	    
	    return @"txt";
	case RTFTextFormat:
	    
	    return @"rtf";
	case HTMLFormat:
	    
	    return @"html";
	case WordDocFormat:
		
		return @"doc";
	case WordXMLFormat:
		
		return @"docx";
	default:
	    NSLog(@"storage format ID is unknown: %d", format);
    }
    
    return @"";
}

//for our nstableview data source
- (int)pathExtensionsCount {
	if (pathExtensions[notesStorageFormat])
	    return (int)[pathExtensions[notesStorageFormat] count];
	
	return 0;
}

- (NSString*)pathExtensionAtIndex:(int)pathIndex {
    return [pathExtensions[notesStorageFormat] objectAtIndex:pathIndex];
}
- (unsigned int)indexOfChosenPathExtension {
	return chosenExtIndices[notesStorageFormat];
}
- (NSString*)chosenPathExtensionForFormat:(int)format {
	if (chosenExtIndices[format] >= [pathExtensions[format] count])
		return [NotationPrefs pathExtensionForFormat:format];
	
	return [pathExtensions[format] objectAtIndex:chosenExtIndices[format]];
}

- (void)addAllowedPathExtension:(NSString*)extension {
    
    NSString *actualExt = [extension stringAsSafePathExtension];
	[pathExtensions[notesStorageFormat] addObject:actualExt];
	
	preferencesChanged = YES;
}

- (BOOL)removeAllowedPathExtensionAtIndex:(unsigned int)extensionIndex {

	if ([pathExtensions[notesStorageFormat] count] > 1 && extensionIndex < [pathExtensions[notesStorageFormat] count]) {
		[pathExtensions[notesStorageFormat] removeObjectAtIndex:extensionIndex];
		
		if (chosenExtIndices[notesStorageFormat] >= [pathExtensions[notesStorageFormat] count])
			chosenExtIndices[notesStorageFormat] = 0;
		
		preferencesChanged = YES;
		return YES;
	}
	return NO;
}
- (BOOL)setChosenPathExtensionAtIndex:(unsigned int)extensionIndex {
	if ([pathExtensions[notesStorageFormat] count] > extensionIndex &&
		[[pathExtensions[notesStorageFormat] objectAtIndex:extensionIndex] length]) {
		chosenExtIndices[notesStorageFormat] = extensionIndex;
		
		preferencesChanged = YES;
		return YES;
	}
	return NO;
}

- (BOOL)setExtension:(NSString*)newExtension atIndex:(unsigned int)oldIndex {
	
    if (oldIndex < [pathExtensions[notesStorageFormat] count]) {
		
		if ([newExtension length] > 0) { 
			[pathExtensions[notesStorageFormat] replaceObjectAtIndex:oldIndex withObject:[newExtension stringAsSafePathExtension]];
			
			preferencesChanged = YES;
		} else if (![(NSString*)[pathExtensions[notesStorageFormat] objectAtIndex:oldIndex] length]) {
			return NO;
		}
    }
	
	return YES;
}

- (BOOL)pathExtensionAllowed:(NSString*)anExtension forFormat:(int)formatID {
	NSUInteger i;
    for (i=0; i<[pathExtensions[formatID] count]; i++) {
		if ([anExtension compare:[pathExtensions[formatID] objectAtIndex:i] 
						 options:NSCaseInsensitiveSearch] == NSOrderedSame) {
			return YES;
		}
    }
	return NO;
}

- (BOOL)catalogEntryAllowed:(NoteCatalogEntry*)catEntry {
    NSString *filename = (NSString*)catEntry->filename;
	
	if (![filename length])
		return NO;
	
	//ignore hidden files and our own database-related files (e.g. if by chance they are given a TEXT file type)
	if ([filename characterAtIndex:0] == '.') {
		return NO;
	}
	if ([filename isEqualToString:NotesDatabaseFileName]) {
		return NO;
	}
	if ([filename isEqualToString:NVJournalFilename]) {
		return NO;
	}
	
	return [self pathExtensionAllowed:[filename pathExtension] forFormat:notesStorageFormat];
    
}

@end
