//
//  NotationPrefs.h
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


#import <Cocoa/Cocoa.h>
#import "NotationController.h"

/* this class is responsible for managing all preferences specific to a notational database,
including encryption, file formats, synchronization, passwords management, and others */

#define EPOC_ITERATION 5

enum { SingleDatabaseFormat = 0, PlainTextFormat, RTFTextFormat, HTMLFormat, WordDocFormat, WordXMLFormat };

extern NSString *NotationPrefsDidChangeNotification;

@interface NotationPrefs : NSObject {
	BOOL doesEncryption, storesPasswordInKeychain, secureTextEntry;
	NSString *keychainDatabaseIdentifier;
	
	//password(s) stored in keychain or otherwise encrypted using notes password
	NSMutableDictionary *syncServiceAccounts;
	
	unsigned int hashIterationCount, keyLengthInBits;
	
	NSColor *foregroundColor;
	NSFont *baseBodyFont;
	int notesStorageFormat;
	BOOL confirmFileDeletion;
	
	unsigned int chosenExtIndices[4];
    NSMutableArray *pathExtensions[4];
	
	NSData *masterSalt, *dataSessionSalt, *verifierKey;
	
	NSString *fileMetadataVolumeUUID;
	
	UInt32 epochIteration;
	BOOL firstTimeUsed;
	BOOL preferencesChanged;
	__weak id delegate;
	
	@private 
	//masterKey is not to be stored anywhere
	NSData *masterKey;
}

NSMutableDictionary *ServiceAccountDictInit(NotationPrefs *prefs, NSString* serviceName);

+ (int)appVersion;
+ (NSMutableArray*)defaultPathExtensionsForFormat:(int)formatID;
@property (nonatomic, readonly) BOOL preferencesChanged;
- (void)setForegroundTextColor:(NSColor*)aColor;
@property (nonatomic, readonly) NSColor *foregroundColor;
- (void)setBaseBodyFont:(NSFont*)aFont;
@property (nonatomic, readonly) NSFont *baseBodyFont;

@property (nonatomic, readonly) BOOL storesPasswordInKeychain;
@property (nonatomic, readonly) int notesStorageFormat;
@property (nonatomic, readonly) BOOL confirmFileDeletion;
@property (nonatomic, readonly) BOOL doesEncryption;
@property (nonatomic, readonly) NSDictionary *syncServiceAccounts;
- (NSDictionary*)syncServiceAccountsForArchiving;
- (NSDictionary*)syncAccountForServiceName:(NSString*)serviceName;
- (NSString*)syncPasswordForServiceName:(NSString*)serviceName;
- (NSUInteger)syncFrequencyInMinutesForServiceName:(NSString*)serviceName;
- (BOOL)syncNotesShouldMergeForServiceName:(NSString*)serviceName;
- (BOOL)syncServiceIsEnabled:(NSString*)serviceName;
@property (nonatomic, readonly) unsigned int keyLengthInBits;
@property (nonatomic, readonly) unsigned int hashIterationCount;
@property (nonatomic, readonly) UInt32 epochIteration;
@property (nonatomic, readonly) BOOL firstTimeUsed;
@property (nonatomic, readonly) BOOL secureTextEntry;

- (void)forgetKeychainIdentifier;
- (const char *)setKeychainIdentifier;
- (SecKeychainItemRef)currentKeychainItem;
- (NSData*)passwordDataFromKeychain;
- (void)removeKeychainData;
- (void)setKeychainData:(NSData*)data;

- (void)setPreferencesAreStored;
- (void)setStoresPasswordInKeychain:(BOOL)value;
- (BOOL)canLoadPassphraseData:(NSData*)passData;
- (BOOL)canLoadPassphrase:(NSString*)pass;
- (void)setPassphraseData:(NSData*)passData inKeychain:(BOOL)inKeychain;
- (void)setPassphraseData:(NSData*)passData inKeychain:(BOOL)inKeychain withIterations:(int)iterationCount;
- (BOOL)encryptDataInNewSession:(NSMutableData*)data;
- (BOOL)decryptDataWithCurrentSettings:(NSMutableData*)data;
- (NSData*)WALSessionKey;

- (void)setNotesStorageFormat:(int)formatID;
- (BOOL)shouldDisplaySheetForProposedFormat:(int)proposedFormat;
- (void)noteFilesCleanupSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void)setConfirmsFileDeletion:(BOOL)value;
- (void)setDoesEncryption:(BOOL)value;
- (void)setSecureTextEntry:(BOOL)value;
- (const char*)keychainSyncAccountNameForService:(NSString*)serviceName;
- (void)setSyncUsername:(NSString*)username forService:(NSString*)serviceName;
- (void)setSyncPassword:(NSString*)password forService:(NSString*)serviceName;
- (void)setSyncFrequency:(NSUInteger)frequencyInMinutes forService:(NSString*)serviceName;
- (void)setSyncEnabled:(BOOL)isEnabled forService:(NSString*)serviceName;
- (void)setSyncShouldMerge:(BOOL)shouldMerge inCurrentAccountForService:(NSString*)serviceName;
- (void)removeSyncPasswordForService:(NSString*)serviceName;
- (void)setKeyLengthInBits:(unsigned int)newLength;

@property (nonatomic, readonly) NSString *fileMetadataVolumeUUID;
- (void)setFileMetadataVolumeUUID:(NSString*)volumeUUID;

+ (NSString*)pathExtensionForFormat:(int)format;

//used to view tableviews
- (NSString*)pathExtensionAtIndex:(int)pathIndex;
- (unsigned int)indexOfChosenPathExtension;
- (NSString*)chosenPathExtensionForFormat:(int)format;
- (int)pathExtensionsCount;

//used to edit tableviews
- (void)addAllowedPathExtension:(NSString*)extension;
- (BOOL)removeAllowedPathExtensionAtIndex:(unsigned int)extensionIndex;
- (BOOL)setChosenPathExtensionAtIndex:(unsigned int)extensionIndex;
- (BOOL)setExtension:(NSString*)newExtension atIndex:(unsigned int)oldIndex;

- (BOOL)pathExtensionAllowed:(NSString*)anExtension forFormat:(int)formatID;

//actually used while searching for files
- (BOOL)catalogEntryAllowed:(NoteCatalogEntry*)catEntry;

@property (nonatomic, weak) id delegate; // zeroing weak reference

@end

@interface NotationPrefs (DelegateMethods)

- (void)databaseEncryptionSettingsChanged;
- (void)syncSettingsChangedForService:(NSString*)serviceName;
- (void)databaseSettingsChangedFromOldFormat:(int)oldFormat;

@end
