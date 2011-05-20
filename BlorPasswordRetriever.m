//
//  BlorPasswordRetriever.m
//  Notation
//
//  Created by Zachary Schneirov on 12/13/06.

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


#import "BlorPasswordRetriever.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NSData_transformations.h"
#import "AttributedPlainText.h"
#import "NotationPrefs.h"
#include "idea_ossl.h"

@implementation BlorPasswordRetriever

- (id)initWithBlor:(NSString*)blorPath {
	if ([super init]) {
		path = [blorPath retain];
		
		couldRetrieveFromKeychain = NO;
		
		//read hash (first 20 bytes) of file
		NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
		hashData = [[handle readDataOfLength:20] retain];
		
		[handle closeFile];
		
		if (!hashData || [hashData length] < 20)
			return nil;
	}
	
	return self;
}

- (IBAction)cancelAction:(id)sender {
	[NSApp stopModalWithCode:0];
	[window close];
	
	if (![[GlobalPrefs defaultPrefs] triedToImportBlor])
		NSRunAlertPanel(NSLocalizedString(@"Note Importing Cancelled", nil), 
						NSLocalizedString(@"You can import your old notes at any time by choosing quotemarkImport...quotemark from the quotemarkNotequotemark menu and selecting your NotationalDatabase.blor file.",nil), 
						NSLocalizedString(@"OK",nil), nil, nil);
}

- (IBAction)importAction:(id)sender {
	//check pw against hash and defaultCStringEncoding
	
	NSData *passData = [[passphraseField stringValue] dataUsingEncoding:[NSString defaultCStringEncoding] allowLossyConversion:NO];
	
	if ([[passData SHA1Digest] isEqualToData:hashData]) {
		
		[NSApp stopModalWithCode:1];
		[window close];
		
	} else {
		NSBeginAlertSheet(NSLocalizedString(@"Sorry, you entered an incorrect passphrase.",nil), NSLocalizedString(@"OK",nil), 
						  nil, nil, window, nil, NULL, NULL, NULL, NSLocalizedString(@"Please try again.",nil));
	}	
	
}

- (NSData*)keychainPasswordData {
	
	NSString *keychainAccountString = [[path stringByAbbreviatingWithTildeInPath] lowercaseString];
    if ([keychainAccountString length] > 255) keychainAccountString = [keychainAccountString substringToIndex:255];
	
    const char *keychainAccountCString = [[keychainAccountString dataUsingEncoding:
				[NSString defaultCStringEncoding] allowLossyConversion:YES] bytes];
	
	UInt32 len;
	void *p = (void *)calloc(256, sizeof(char));
	if (kcfindgenericpassword("NV", keychainAccountCString, 255, p, &len, NULL) != noErr) {
		free(p);
		return NULL;
	}
	
	return [NSData dataWithBytesNoCopy:p length:len freeWhenDone:YES];
}

- (NSData*)validPasswordHashData {
	
	[originalPasswordString release];
	originalPasswordString = nil;
	
	//try to get PW from keychain. if that fails, request from user
	NSData *passwordData = [self keychainPasswordData];
	if (passwordData && [[passwordData SHA1Digest] isEqualToData:hashData]) {
		couldRetrieveFromKeychain = YES;
		originalPasswordString = [[NSString alloc] initWithData:passwordData encoding:[NSString defaultCStringEncoding]];
		
		return [passwordData BrokenMD5Digest];
	}
	
	//run dialog and grab PW
	
	if (!window) {
		if (![NSBundle loadNibNamed:@"BlorPasswordRetriever" owner:self])  {
			NSLog(@"Failed to load BlorPasswordRetriever.nib");
			NSBeep();
			return NULL;
		}
	}
	
	[helpStringField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Please enter the passphrase to import old notes at %@.",nil), 
		[path stringByAbbreviatingWithTildeInPath]]];
	
	int result = [NSApp runModalForWindow:window];
	
	NSString *passwordString = [passphraseField stringValue];
	passwordData = [passwordString dataUsingEncoding:[NSString defaultCStringEncoding] allowLossyConversion:NO];
	
	if (result && [[passwordData SHA1Digest] isEqualToData:hashData]) {
		originalPasswordString = [passwordString copy];
		
		[passphraseField setStringValue:@""];
		
		return [passwordData BrokenMD5Digest];
	}
	
	[passphraseField setStringValue:@""];
	
	return NULL;
}

- (NSString*)originalPasswordString {
	return originalPasswordString;
}

- (BOOL)canRetrieveFromKeychain {
	return couldRetrieveFromKeychain;
}

- (void)awakeFromNib {
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textDidChange:)
												 name:NSControlTextDidChangeNotification object:passphraseField];
}	

- (void)textDidChange:(NSNotification *)aNotification {
	[importButton setEnabled:([[passphraseField stringValue] length] > 0)];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[hashData release];
	[path release];
	[originalPasswordString release];
	
	[super dealloc];
}

@end


@implementation BlorNoteEnumerator

- (id)initWithBlor:(NSString*)blorPath passwordHashData:(NSData*)passwordHashData {
	if ([super init]) {
		path = [blorPath retain];
		
		if (!(keyData = [passwordHashData retain]))
			return nil;
		
		if (!(blorData = [[NSMutableData dataWithContentsOfFile:path] retain]))
			return nil;
			
		if ([blorData length] < 28) {
			NSLog(@"read data is too small (%d) to hold any notes!", [blorData length]);
			return nil;
		}
		
		successfullyReadNoteCount = 0;
		suspectedNoteCount = *(unsigned int*)([blorData bytes] + 20);
		suspectedNoteCount = CFSwapInt32BigToHost(suspectedNoteCount);
			
		currentByteOffset = 24;
		//read past the # of notes marker--we're just going to read as many notes as possible
	}
	
	return self;
}

- (void)dealloc {
	[blorData release];
	[keyData release];
	
	[super dealloc];
}

- (void)decryptNextBytesOfLength:(long)length {
	unsigned char iv[] = {
		0x50, 0x7E, 0x4C, 0x17,
		0x99, 0x3A, 0x07, 0x01
    };
	
    int num = 0;
    IDEA_KEY_SCHEDULE enc;    
	
    idea_set_encrypt_key([keyData bytes], &enc);
	
	unsigned char *bytes = [blorData mutableBytes] + currentByteOffset;
	
    idea_cfb64_encrypt(bytes, bytes, length, &enc, iv, &num, IDEA_DECRYPT);	
}

- (unsigned int)suspectedNoteCount {
	return suspectedNoteCount;
}


#define ASSERT_CAN_READ_BYTE_COUNT(n) do { \
	if (!((n) + currentByteOffset <= [blorData length])) { \
		NSLog(@"Attempted to read %d bytes past the length of the blor!", ((n) + currentByteOffset) - [blorData length]);\
		return nil;\
	} \
} while (0)

- (id)nextNote {
	int titleBytesLength; 
	//read length of title
	ASSERT_CAN_READ_BYTE_COUNT(sizeof(titleBytesLength));
	titleBytesLength = *(int*)([blorData bytes] + currentByteOffset);
	titleBytesLength = CFSwapInt32BigToHost(titleBytesLength);
	currentByteOffset += sizeof(titleBytesLength);
	
	//read/decrypt title
	ASSERT_CAN_READ_BYTE_COUNT(titleBytesLength);
	[self decryptNextBytesOfLength:titleBytesLength];
	NSData *titleData = [NSData dataWithBytesNoCopy:[blorData mutableBytes] + currentByteOffset length:titleBytesLength freeWhenDone:NO];
	NSString *titleString = [[NSString alloc] initWithData:titleData encoding:NSUnicodeStringEncoding];
	currentByteOffset += titleBytesLength;
	
	int bodyBufferBytesLength, bodyBytesLength;
	//read lengths of body
	ASSERT_CAN_READ_BYTE_COUNT(sizeof(bodyBufferBytesLength));
	bodyBufferBytesLength = *(int*)([blorData bytes] + currentByteOffset);
	bodyBufferBytesLength = CFSwapInt32BigToHost(bodyBufferBytesLength);
	currentByteOffset += sizeof(bodyBufferBytesLength);
	
	ASSERT_CAN_READ_BYTE_COUNT(sizeof(bodyBytesLength));
	bodyBytesLength = *(int*)([blorData bytes] + currentByteOffset);
	bodyBytesLength = CFSwapInt32BigToHost(bodyBytesLength);
	currentByteOffset += sizeof(bodyBytesLength);

	//read/decrypt body
	ASSERT_CAN_READ_BYTE_COUNT(bodyBytesLength);
	[self decryptNextBytesOfLength:bodyBytesLength];
	NSData *bodyData = [NSData dataWithBytesNoCopy:[blorData mutableBytes] + currentByteOffset length:bodyBytesLength freeWhenDone:NO];
	NSString *bodyString = [[NSString alloc] initWithData:bodyData encoding:NSUnicodeStringEncoding];
	currentByteOffset += bodyBufferBytesLength;
	//do we need to assert bodyBufferBytesLength, too?
	
	//create new note and return it
	
	NSMutableAttributedString *attributedBody = [[NSMutableAttributedString alloc] initWithString:bodyString
																					   attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
	[attributedBody addLinkAttributesForRange:NSMakeRange(0, [attributedBody length])];
	[attributedBody addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [attributedBody length])];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:attributedBody title:titleString delegate:nil format:SingleDatabaseFormat labels:nil];

	[bodyString release];
	[attributedBody release];
	[titleString release];
	
	successfullyReadNoteCount++;
	
	return [note autorelease];
}

@end
