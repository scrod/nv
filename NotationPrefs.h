//
//  NotationPrefs.h
//  Notation
//
//  Created by Zachary Schneirov on 4/1/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "NotationController.h"

/* this class is responsible for managing all preferences specific to a notational database,
including encryption, file formats, synchronization, passwords management, and others */

enum { SingleDatabaseFormat = 0, PlainTextFormat, RTFTextFormat, HTMLFormat, WordDocFormat, WordXMLFormat };

@interface NotationPrefs : NSObject {
	BOOL doesEncryption, storesPasswordInKeychain, secureTextEntry;
	NSString *keychainDatabaseIdentifier;
	NSString *serverUserName; //password is stored in keychain or otherwise encrypted using notes password
	unsigned int hashIterationCount, keyLengthInBits;
	
	NSFont *baseBodyFont;
	int notesStorageFormat;
	BOOL confirmFileDeletion;
	
    NSMutableArray *typeStrings[4], *pathExtensions[4];
    OSType *allowedTypes;
	
	NSData *masterSalt, *dataSessionSalt, *verifierKey;
	
	BOOL firstTimeUsed;
	BOOL preferencesChanged;
	id delegate;
	
	@private 
	//masterKey is not to be stored anywhere
	NSData *masterKey;
}

+ (NSMutableArray*)defaultTypeStringsForFormat:(int)formatID;
+ (NSMutableArray*)defaultPathExtensionsForFormat:(int)formatID;
- (BOOL)preferencesChanged;
- (void)setBaseBodyFont:(NSFont*)aFont;
- (NSFont*)baseBodyFont;

- (BOOL)storesPasswordInKeychain;
- (int)notesStorageFormat;
- (BOOL)confirmFileDeletion;
- (BOOL)doesEncryption;
- (NSString*)serverUserName;
- (unsigned int)keyLengthInBits;
- (unsigned int)hashIterationCount;
- (BOOL)firstTimeUsed;
- (BOOL)secureTextEntry;

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

- (void)setSynchronizeNotesWithServer:(BOOL)value;
- (void)setNotesStorageFormat:(int)formatID;
- (BOOL)shouldDisplaySheetForProposedFormat:(int)proposedFormat;
- (void)noteFilesCleanupSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void)setConfirmsFileDeletion:(BOOL)value;
- (void)setDoesEncryption:(BOOL)value;
- (void)setSecureTextEntry:(BOOL)value;
- (void)setServerUserName:(NSString*)aUserName;
- (void)setServerPassword:(NSString*)aPassword;
- (void)setKeyLengthInBits:(unsigned int)newLength;

+ (NSString*)pathExtensionForFormat:(int)format;

//used to view tableviews
- (NSString*)typeStringAtIndex:(int)typeIndex;
- (NSString*)pathExtensionAtIndex:(int)pathIndex;
- (int)typeStringsCount;
- (int)pathExtensionsCount;

//used to edit tableviews
- (void)addAllowedPathExtension:(NSString*)extension;
- (void)removeAllowedPathExtensionAtIndex:(unsigned int)extensionIndex;
- (void)addAllowedType:(NSString*)type;
- (void)removeAllowedTypeAtIndex:(unsigned int)index;
- (BOOL)setExtension:(NSString*)newExtension atIndex:(unsigned int)oldIndex;
- (BOOL)setType:(NSString*)newType atIndex:(unsigned int)oldIndex;

//actually used while searching for files
- (void)updateOSTypesArray;
- (BOOL)catalogEntryAllowed:(NoteCatalogEntry*)catEntry;

- (id)delegate;
- (void)setDelegate:(id)aDelegate;

@end

@interface NotationPrefs (DelegateMethods)

- (void)databaseEncryptionSettingsChanged;
- (void)serverSynchronizationSettingsChanged;
- (void)databaseSettingsChangedFromOldFormat:(int)oldFormat;

@end
