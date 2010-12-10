//
//  NotationPrefs.m
//  Notation
//
//  Created by Zachary Schneirov on 4/1/06.

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


#import "NotationPrefs.h"
#import "GlobalPrefs.h"
#import "NSString_NV.h"
#import "SimplenoteSession.h"
#import "NSCollection_utils.h"
#import "NotationPrefsViewController.h"
#import "NSData_transformations.h"
#import "NotationFileManager.h"
#include <Carbon/Carbon.h>
#include <CoreServices/CoreServices.h>
#include <Security/Security.h>
#include <ApplicationServices/ApplicationServices.h>

#define DEFAULT_HASH_ITERATIONS 8000
#define DEFAULT_KEY_LENGTH 256

#define KEYCHAIN_SERVICENAME "Notational Velocity"

#define INIT_DICT_ACCT() NSMutableDictionary *accountDict = ServiceAccountDictInit(self, serviceName)

NSString *SyncPrefsDidChangeNotification = @"SyncPrefsDidChangeNotification";

@implementation NotationPrefs

NSMutableDictionary *ServiceAccountDictInit(NotationPrefs *prefs, NSString* serviceName) {
	NSMutableDictionary *accountDict = [prefs->syncServiceAccounts objectForKey:serviceName];
	if (!accountDict) [prefs->syncServiceAccounts setObject:(accountDict = [[NSMutableDictionary alloc] init]) forKey:serviceName];
	return accountDict;
}

+ (int)appVersion {
	return [[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"] intValue];
}

- (id)init {
    if ([super init]) {
		allowedTypes = NULL;
		
		unsigned int i;
		for (i=0; i<=6; i++) {
			typeStrings[i] = [[NotationPrefs defaultTypeStringsForFormat:i] retain];
			pathExtensions[i] = [[NotationPrefs defaultPathExtensionsForFormat:i] retain];
		}
		
		confirmFileDeletion = YES;
		storesPasswordInKeychain = secureTextEntry = doesEncryption = NO;
		syncServiceAccounts = [[NSMutableDictionary alloc] init];
		notesStorageFormat = SingleDatabaseFormat;
		hashIterationCount = DEFAULT_HASH_ITERATIONS;
		keyLengthInBits = DEFAULT_KEY_LENGTH;
		baseBodyFont = [[[GlobalPrefs defaultPrefs] noteBodyFont] retain];
		epochIteration = 0;
		
		[self updateOSTypesArray];
		
		firstTimeUsed = preferencesChanged = YES;
		
    }
    return self;
}

- (id)initWithCoder:(NSCoder*)decoder {
    if ([super init]) {
		NSAssert([decoder allowsKeyedCoding], @"Keyed decoding only!");
		
		//if we're initializing from an archive, we've obviously been run at least once before
		firstTimeUsed = NO;
		
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
				
		confirmFileDeletion = [decoder decodeBoolForKey:VAR_STR(confirmFileDeletion)];
		
		unsigned int i;
		for (i=0; i<4; i++) {
			if (!(typeStrings[i] = [[decoder decodeObjectForKey:[VAR_STR(typeStrings) stringByAppendingFormat:@".%d",i]] retain]))
				typeStrings[i] = [[NotationPrefs defaultTypeStringsForFormat:i] retain];
			if (!(pathExtensions[i] = [[decoder decodeObjectForKey:[VAR_STR(pathExtensions) stringByAppendingFormat:@".%d",i]] retain]))
				pathExtensions[i] = [[NotationPrefs defaultPathExtensionsForFormat:i] retain];
		}
		
		if (!(syncServiceAccounts = [[decoder decodeObjectForKey:VAR_STR(syncServiceAccounts)] retain]))
			syncServiceAccounts = [[NSMutableDictionary alloc] init];
		keychainDatabaseIdentifier = [[decoder decodeObjectForKey:VAR_STR(keychainDatabaseIdentifier)] retain];
		
		masterSalt = [[decoder decodeObjectForKey:VAR_STR(masterSalt)] retain];
		dataSessionSalt = [[decoder decodeObjectForKey:VAR_STR(dataSessionSalt)] retain];
		verifierKey = [[decoder decodeObjectForKey:VAR_STR(verifierKey)] retain];
		
		doesEncryption = doesEncryption && verifierKey && masterSalt;
		
		[self updateOSTypesArray];
    }
	
    preferencesChanged = NO;
	
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	NSAssert([coder allowsKeyedCoding], @"Keyed encoding only!");
	
	/* epochIteration:
	 0: .Blor files
	 1: First NSArchiver (was unused--maps to 0)
	 2: First NSKeyedArchiver
	 3: First syncServicesMD and date created/modified syncing to files
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
		
	unsigned int i;
	for (i=0; i<4; i++) {	
		[coder encodeObject:typeStrings[i] forKey:[VAR_STR(typeStrings) stringByAppendingFormat:@".%d",i]];
		[coder encodeObject:pathExtensions[i] forKey:[VAR_STR(pathExtensions) stringByAppendingFormat:@".%d",i]];
	}
	
	[coder encodeObject:[self syncServiceAccountsForArchiving] forKey:VAR_STR(syncServiceAccounts)];
	
	[coder encodeObject:keychainDatabaseIdentifier forKey:VAR_STR(keychainDatabaseIdentifier)];
	
	[coder encodeObject:masterSalt forKey:VAR_STR(masterSalt)];
	[coder encodeObject:dataSessionSalt forKey:VAR_STR(dataSessionSalt)];
	[coder encodeObject:verifierKey forKey:VAR_STR(verifierKey)];
}


- (void)dealloc {
    
    unsigned int i;
    for (i=0; i<4; i++) {
	[typeStrings[i] release];
	[pathExtensions[i] release];
    }
    if (allowedTypes)
	free(allowedTypes);
	
	[syncServiceAccounts release];
	[keychainDatabaseIdentifier release];
	[baseBodyFont release];
    
    [super dealloc];
}

+ (NSMutableArray*)defaultTypeStringsForFormat:(int)formatID {
    switch (formatID) {
	case SingleDatabaseFormat:
	    return [NSMutableArray arrayWithCapacity:0];
	case MarkupTextFormat: 
		// (fall-through intended)
	case PlainTextFormat: 
	    return [NSMutableArray arrayWithObjects:[(id)UTCreateStringForOSType(TEXT_TYPE_ID) autorelease], 
			[(id)UTCreateStringForOSType(UTXT_TYPE_ID) autorelease], nil];
	case RTFTextFormat: 
	    return [NSMutableArray arrayWithObjects:[(id)UTCreateStringForOSType(RTF_TYPE_ID) autorelease], nil];
	case HTMLFormat:
	    return [NSMutableArray arrayWithObjects:[(id)UTCreateStringForOSType(HTML_TYPE_ID) autorelease], nil];
	case WordDocFormat:
		return [NSMutableArray arrayWithObjects:[(id)UTCreateStringForOSType(WORD_DOC_TYPE_ID) autorelease], nil];
	default:
	    NSLog(@"Unknown format ID: %d", formatID);
    }
    
    return [NSMutableArray arrayWithCapacity:0];
}

+ (NSMutableArray*)defaultPathExtensionsForFormat:(int)formatID {
    NSLog(@"%d",formatID);
    switch (formatID) {
	case SingleDatabaseFormat:
	    return [NSMutableArray arrayWithCapacity:0];
	case PlainTextFormat: 
	    return [NSMutableArray arrayWithObjects:@"txt", @"text", @"utf8", nil];
	case MarkupTextFormat:
		return [NSMutableArray arrayWithObjects:@"md", @"mmd", @"mdown", @"markdown", @"textile", @"text", @"txt", nil];
	case RTFTextFormat: 
	    return [NSMutableArray arrayWithObjects:@"rtf", nil];
	case HTMLFormat:
	    return [NSMutableArray arrayWithObjects:@"htm", @"html", nil];
	case WordDocFormat:
		return [NSMutableArray arrayWithObjects:@"doc", nil];
	case WordXMLFormat:
		return [NSMutableArray arrayWithObjects:@"docx", nil];
	default:
	    NSLog(@"Unknown format ID: %d", formatID);
    }
    
    return [NSMutableArray arrayWithCapacity:0];
}

- (BOOL)preferencesChanged {
	return preferencesChanged;
}

- (BOOL)storesPasswordInKeychain {
	return storesPasswordInKeychain;
}

- (int)notesStorageFormat {
	return notesStorageFormat;
}
- (BOOL)confirmFileDeletion {
    return confirmFileDeletion;
}

- (BOOL)doesEncryption {
	return doesEncryption;
}

- (BOOL)secureTextEntry {
	return secureTextEntry;
}

- (NSDictionary*)syncServiceAccounts {
	return syncServiceAccounts;
}

- (NSDictionary*)syncAccountForServiceName:(NSString*)serviceName {
	return [syncServiceAccounts objectForKey:serviceName];
}

- (NSString*)syncPasswordForServiceName:(NSString*)serviceName {
	//if non-existing, fetch from keychain and cache
	
	INIT_DICT_ACCT();
	
	NSString *password = [accountDict objectForKey:@"password"];
	if (password) return password;
	
	//fetch keychain
	void *passwordData = NULL;
	UInt32 passwordLength = 0;
	SecKeychainItemRef returnedItem = NULL;	
	
	const char *kcSyncAccountName = [self keychainSyncAccountNameForService:serviceName];
	if (!kcSyncAccountName) return nil;
	
	OSStatus err = SecKeychainFindGenericPassword(NULL, strlen(KEYCHAIN_SERVICENAME), KEYCHAIN_SERVICENAME,
												  strlen(kcSyncAccountName), kcSyncAccountName, &passwordLength, &passwordData, &returnedItem);
	if (err != noErr) {
		NSLog(@"Error finding keychain password for service account %@: %d\n", serviceName, err);
		return nil;
	}
	password = [[[NSString alloc] initWithBytes:passwordData length:passwordLength encoding:NSUTF8StringEncoding] autorelease];
	
	//cache password found in keychain
	[accountDict setObject:password forKey:@"password"];
	
	SecKeychainItemFreeContent(NULL, passwordData);
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

- (unsigned int)keyLengthInBits {
    return keyLengthInBits;
}

- (unsigned int)hashIterationCount {
	return hashIterationCount;
}

- (void)setPreferencesAreStored {
	preferencesChanged = NO;
}

- (UInt32)epochIteration {
	return epochIteration;
}

- (BOOL)firstTimeUsed {
	return firstTimeUsed;
}

- (void)setBaseBodyFont:(NSFont*)aFont {
	[baseBodyFont autorelease];
	baseBodyFont = [aFont retain];
		
	preferencesChanged = YES;
}

- (NSFont*)baseBodyFont {
	
	return baseBodyFont;
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
	SecKeychainItemRef returnedItem = NULL;
	
	const char *accountName = [self setKeychainIdentifier];
	
	OSStatus err = SecKeychainFindGenericPassword(NULL, strlen(KEYCHAIN_SERVICENAME), KEYCHAIN_SERVICENAME,
											 strlen(accountName), accountName, NULL, NULL, &returnedItem);
	if (err != noErr)
		return NULL;
	
	return returnedItem;
}

- (void)removeKeychainData {
	SecKeychainItemRef itemRef = [self currentKeychainItem];
	if (itemRef) {
		OSStatus err = SecKeychainItemDelete(itemRef);
		if (err != noErr)
			NSLog(@"Error deleting keychain item: %d", err);
		CFRelease(itemRef);
	}
}

- (NSData*)passwordDataFromKeychain {
	void *passwordData = NULL;
	UInt32 passwordLength = 0;
	const char *accountName = [self setKeychainIdentifier];
	SecKeychainItemRef returnedItem = NULL;	
	
	OSStatus err = SecKeychainFindGenericPassword(NULL,
												  strlen(KEYCHAIN_SERVICENAME), KEYCHAIN_SERVICENAME,
												  strlen(accountName), accountName,
												  &passwordLength, &passwordData,
												  &returnedItem);
	if (err != noErr) {
		NSLog(@"Error finding keychain password for account %s: %d\n", accountName, err);
		return nil;
	}
	NSData *data = [NSData dataWithBytes:passwordData length:passwordLength];
	
	bzero(passwordData, passwordLength);
	
	SecKeychainItemFreeContent(NULL, passwordData);
	
	return data;
}

- (void)setKeychainData:(NSData*)data {
	
	OSStatus status = noErr;
	
	SecKeychainItemRef itemRef = [self currentKeychainItem];
	if (itemRef) {
		//modify existing data; item already exists
		
		const char *accountName = [self setKeychainIdentifier];
		
		SecKeychainAttribute attrs[] = {
		{ kSecAccountItemAttr, strlen(accountName), (char*)accountName },
		{ kSecServiceItemAttr, strlen(KEYCHAIN_SERVICENAME), (char*)KEYCHAIN_SERVICENAME } };
		
		const SecKeychainAttributeList attributes = { sizeof(attrs) / sizeof(attrs[0]), attrs };
		
		if (noErr != (status = SecKeychainItemModifyAttributesAndData(itemRef, &attributes, [data length], [data bytes]))) {
			NSLog(@"Error modifying keychain data with new passphrase-data: %d", status);
		}
		
		CFRelease(itemRef);
		
	} else {
		const char *accountName = [self setKeychainIdentifier];
		
		//add new data; item does not exist
		if (noErr != (status = SecKeychainAddGenericPassword(NULL, strlen(KEYCHAIN_SERVICENAME), KEYCHAIN_SERVICENAME,
															 strlen(accountName), accountName, [data length], [data bytes], NULL))) {
			NSLog(@"Error adding new passphrase item to keychain: %d", status);
		}
	}
}

- (void)setStoresPasswordInKeychain:(BOOL)value {
	storesPasswordInKeychain = value;
	preferencesChanged = YES;
	
	if (!storesPasswordInKeychain)
		[self removeKeychainData];
}

- (BOOL)canLoadPassphraseData:(NSData*)passData {
	
	int keyLength = keyLengthInBits/8;
	
	//compute master key given stored salt and # of iterations
	NSData *computedMasterKey = [passData derivedKeyOfLength:keyLength salt:masterSalt iterations:hashIterationCount];

	//compute verify key given "verify" salt and 1 iteration
	NSData *verifySalt = [NSData dataWithBytesNoCopy:VERIFY_SALT length:sizeof(VERIFY_SALT) freeWhenDone:NO];
	NSData *computedVerifyKey = [computedMasterKey derivedKeyOfLength:keyLength salt:verifySalt iterations:1];
	
	//check against verify key data
	if ([computedVerifyKey isEqualToData:verifierKey]) {
		//if computedMasterKey is good, and we don't already have a master key, then this is it
		if (!masterKey)
			masterKey = [computedMasterKey retain];
		
		return YES;
	}
	
	return NO;
	
}

- (BOOL)canLoadPassphrase:(NSString*)pass {
	return [self canLoadPassphraseData:[pass dataUsingEncoding:NSUTF8StringEncoding]];
}

- (BOOL)encryptDataInNewSession:(NSMutableData*)data {
	//ideally we would vary AES algo between 128 and 256 bits depending on key length, 
	//and scale beyond with triplets, quintuplets, and septuplets--but key is not currently user-settable

	//create new dataSessionSalt and key here
	[dataSessionSalt release];
	dataSessionSalt = [[NSData randomDataOfLength:256] retain];
	
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
	[masterSalt release];
	masterSalt = [[NSData randomDataOfLength:256] retain];

	//compute and set master key given salt and # of iterations
	[masterKey release];
	masterKey = [[passData derivedKeyOfLength:keyLength salt:masterSalt iterations:hashIterationCount] retain];
	
	//compute and set verify key from master key
	[verifierKey release];
	NSData *verifySalt = [NSData dataWithBytesNoCopy:VERIFY_SALT length:sizeof(VERIFY_SALT) freeWhenDone:NO];
	verifierKey = [[masterKey derivedKeyOfLength:keyLength salt:verifySalt iterations:1] retain];

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
		int oldFormat = notesStorageFormat;
		notesStorageFormat = formatID;	
		preferencesChanged = YES;
		
		[self updateOSTypesArray];
		
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
	
	if (returnCode != NSAlertAlternateReturn)
		//didn't cancel
		[self setNotesStorageFormat:newNoteStorageFormat];
	
	if (returnCode == NSAlertOtherReturn)
		//tell delegate to delete all its notes' files
		[delegate trashRemainingNoteFilesInDirectory];
	//but what if the files remain after switching to a single-db format--and then the user deletes a bunch of the files themselves?
	//should we switch the currentFormatIDs of those notes to single-db? I guess.
	
	if ([(id)contextInfo respondsToSelector:@selector(notesStorageFormatDidChange)])
		[(NotationPrefsViewController*)contextInfo notesStorageFormatDidChange];
	
	if (returnCode != NSAlertAlternateReturn) {
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
		[verifierKey release]; verifierKey = nil;
		[masterKey release]; masterKey = nil;
	}
	
	if (oldValue != value) {
		if ([delegate respondsToSelector:@selector(databaseEncryptionSettingsChanged)])
			[delegate databaseEncryptionSettingsChanged];
	}
}

- (void)setSecureTextEntry:(BOOL)value {
	//make application active to simplify balancing
	//(what, someone will be setting this by command-clicking in a window?)
	[NSApp activateIgnoringOtherApps:YES];
	
	secureTextEntry = value;
	
	preferencesChanged = YES;
	
	if (secureTextEntry) {
		EnableSecureEventInput();
	} else {
		DisableSecureEventInput();
	}
}

- (void)setSyncEnabled:(BOOL)isEnabled forService:(NSString*)serviceName {
	INIT_DICT_ACCT();
	
	if ([self syncServiceIsEnabled:serviceName] != isEnabled) {
		[accountDict setObject:[NSNumber numberWithBool:isEnabled] forKey:@"enabled"];
		
		preferencesChanged = YES;
		[delegate syncSettingsChangedForService:serviceName];
	}
}

- (void)setSyncFrequency:(NSUInteger)frequencyInMinutes forService:(NSString*)serviceName {
	INIT_DICT_ACCT();
	
	if ([self syncFrequencyInMinutesForServiceName:serviceName] != frequencyInMinutes) {
		[accountDict setObject:[NSNumber numberWithUnsignedInt:frequencyInMinutes] forKey:@"frequency"];
		preferencesChanged = YES;
		[delegate syncSettingsChangedForService:serviceName];
	}
}

- (void)setSyncShouldMerge:(BOOL)shouldMerge inCurrentAccountForService:(NSString*)serviceName {
	INIT_DICT_ACCT();
	
	if ([self syncNotesShouldMergeForServiceName:serviceName] != shouldMerge) {
		NSString *username = [accountDict objectForKey:@"username"];
		if (username) {
			NSLog(@"%s: %d, %@", _cmd, shouldMerge, username);
			if (shouldMerge) {
				[accountDict setObject:username forKey:@"shouldmerge"];
			} else {
				[accountDict removeObjectForKey:@"shouldmerge"];
			}
			preferencesChanged = YES;
		} else {
			NSLog(@"%s: no username found in %@", serviceName);
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
			//insert this password into the keychain for this service
			SecKeychainItemRef itemRef = NULL;
			if (SecKeychainFindGenericPassword(NULL, strlen(KEYCHAIN_SERVICENAME), KEYCHAIN_SERVICENAME, strlen(kcSyncAccountName), kcSyncAccountName, NULL, NULL, &itemRef) != noErr) {
				itemRef = NULL;
			}
			if (itemRef) {
				//modify existing data; item already exists
				SecKeychainAttribute attrs[] = {
					{ kSecAccountItemAttr, strlen(kcSyncAccountName), (char*)kcSyncAccountName },
					{ kSecServiceItemAttr, strlen(KEYCHAIN_SERVICENAME), (char*)KEYCHAIN_SERVICENAME } };
				
				const SecKeychainAttributeList attributes = { sizeof(attrs) / sizeof(attrs[0]), attrs };
				
				OSStatus status = noErr;
				if (noErr != (status = SecKeychainItemModifyAttributesAndData(itemRef, &attributes, [passwordData length], [passwordData bytes]))) {
					NSLog(@"Error modifying keychain data with different service password: %d", status);
				}
				CFRelease(itemRef);
			} else {
				//add new data; item does not exist
				OSStatus status = noErr;
				if (noErr != (status = SecKeychainAddGenericPassword(NULL, strlen(KEYCHAIN_SERVICENAME), KEYCHAIN_SERVICENAME,
																	 strlen(kcSyncAccountName), kcSyncAccountName, [passwordData length], [passwordData bytes], NULL))) {
					NSLog(@"Error adding new service password to keychain: %d", status);
				}
			}
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
			SecKeychainItemRef itemRef = NULL;
			if (SecKeychainFindGenericPassword(NULL, strlen(KEYCHAIN_SERVICENAME), KEYCHAIN_SERVICENAME, strlen(kcSyncAccountName), kcSyncAccountName, NULL, NULL, &itemRef) != noErr) {
				itemRef = NULL;
			}	
			if (itemRef) {
				OSStatus err = SecKeychainItemDelete(itemRef);
				if (err != noErr) NSLog(@"Error deleting keychain item for service %@: %d, serviceName", err);
				CFRelease(itemRef);
			}
		} else {
			NSLog(@"not removing password for %@ because a keychain sync account name couldn't be created", serviceName);
		}
		
		[delegate syncSettingsChangedForService:serviceName];
	}
}

- (void)checkForKnownRedundantSyncConduitsAtPath:(NSString*)dbPath {
	//is inside dropbox folder and notes are separate files
	//is set to sync with any service
	//then display warning
	
	NSArray *enabledValues = [[syncServiceAccounts allValues] objectsFromDictionariesForKey:@"enabled"];	
	if ([enabledValues containsObject:[NSNumber numberWithBool:YES]] && SingleDatabaseFormat != notesStorageFormat) {
		//this DB is syncing with a service and is storing separate files; could it be syncing with anything else, too?
		
		//this logic will need to be more sophisticated anyway when multiple sync services are supported
		NSString *syncServiceTitle = [SimplenoteSession localizedServiceTitle];
		
		NSDictionary *stDict = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hogbaysoftware.SimpleText"];
		NSString *simpleTextFolder = [stDict objectForKey:@"SyncedDocumentsPathKey"];
		if (!simpleTextFolder) simpleTextFolder = [NSHomeDirectory() stringByAppendingPathComponent:@"SimpleText"];
		//for dropbox, a 'select value from config where key = "dropbox_path";' sqlite query would be necessary to get the true path
		NSString *dropboxFolder = [NSHomeDirectory() stringByAppendingPathComponent:@"Dropbox"];
		
		NSString *offendingFileConduitName = nil;
		if ([[dbPath lowercaseString] hasPrefix:[simpleTextFolder lowercaseString]]) {
			offendingFileConduitName = NSLocalizedString(@"SimpleText", nil);
		} else if ([[dbPath lowercaseString] hasPrefix:[dropboxFolder lowercaseString]]) {
			offendingFileConduitName = NSLocalizedString(@"Dropbox", nil);
		}
		if (offendingFileConduitName) {
			NSRunAlertPanel([NSString stringWithFormat:NSLocalizedString(@"<Feedback loop warning title>", nil), offendingFileConduitName, syncServiceTitle], 
							[NSString stringWithFormat:NSLocalizedString(@"<Feedback loop warning message>", nil), syncServiceTitle], NSLocalizedString(@"OK", nil), nil, nil);
		}
	}
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
	case MarkupTextFormat:
            
		return @"md";
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
- (int)typeStringsCount {
	if (typeStrings[notesStorageFormat])
		return [typeStrings[notesStorageFormat] count];
	
	return 0;
}
- (int)pathExtensionsCount {
	if (pathExtensions[notesStorageFormat])
	    return [pathExtensions[notesStorageFormat] count];
	
	return 0;
}

- (NSString*)typeStringAtIndex:(int)typeIndex {

    return [typeStrings[notesStorageFormat] objectAtIndex:typeIndex];
}
- (NSString*)pathExtensionAtIndex:(int)pathIndex {
    return [pathExtensions[notesStorageFormat] objectAtIndex:pathIndex];
}

- (void)updateOSTypesArray {
    if (!typeStrings[notesStorageFormat])
	return;
    
    unsigned int i, newSize = sizeof(OSType) * [typeStrings[notesStorageFormat] count];
    allowedTypes = (OSType*)realloc(allowedTypes, newSize);
	
    for (i=0; i<[typeStrings[notesStorageFormat] count]; i++)
		allowedTypes[i] = UTGetOSTypeFromString((CFStringRef)[typeStrings[notesStorageFormat] objectAtIndex:i]);
}

- (void)addAllowedPathExtension:(NSString*)extension {
    
    NSString *actualExt = [extension stringAsSafePathExtension];
	[pathExtensions[notesStorageFormat] addObject:actualExt];
    
    preferencesChanged = YES;
}

- (void)removeAllowedPathExtensionAtIndex:(unsigned int)extensionIndex {

    [pathExtensions[notesStorageFormat] removeObjectAtIndex:extensionIndex];
	
    preferencesChanged = YES;
}

- (void)addAllowedType:(NSString*)type {
    
	if (type) {
		[typeStrings[notesStorageFormat] addObject:[type fourCharTypeString]];
		[self updateOSTypesArray];
		
		preferencesChanged = YES;
	}
}

- (void)removeAllowedTypeAtIndex:(unsigned int)typeIndex {
	[typeStrings[notesStorageFormat] removeObjectAtIndex:typeIndex];
	[self updateOSTypesArray];
	
	preferencesChanged = YES;
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

- (BOOL)setType:(NSString*)newType atIndex:(unsigned int)oldIndex {
	
    if (oldIndex < [typeStrings[notesStorageFormat] count]) {
		
		if ([newType length] > 0) {
			[typeStrings[notesStorageFormat] replaceObjectAtIndex:oldIndex withObject:[newType fourCharTypeString]];
			[self updateOSTypesArray];
				
			preferencesChanged = YES;
				
			return YES;
		}
		if (!UTGetOSTypeFromString((CFStringRef)[typeStrings[notesStorageFormat] objectAtIndex:oldIndex])) {
			return NO;
		}
    }
	
	return YES;
}

- (BOOL)catalogEntryAllowed:(NoteCatalogEntry*)catEntry {
    unsigned int i;
	
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
	if ([filename isEqualToString:@"Interim Note-Changes"]) {
		return NO;
	}
	
    for (i=0; i<[pathExtensions[notesStorageFormat] count]; i++) {
		if ([[filename pathExtension] compare:[pathExtensions[notesStorageFormat] objectAtIndex:i] 
									  options:NSCaseInsensitiveSearch] == NSOrderedSame) {
			return YES;
		}
    }
    
    for (i=0; i<[typeStrings[notesStorageFormat] count]; i++) {
		if (catEntry->fileType == allowedTypes[i]) {
			return YES;
		}
    }
    
    return NO;
    
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}


@end
