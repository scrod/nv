//
//  BlorPasswordRetriever.m
//  Notation
//
//  Created by Zachary Schneirov on 12/13/06.

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


#import "BlorPasswordRetriever.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NSData_transformations.h"
#import "AttributedPlainText.h"
#import "NotationPrefs.h"
#include "idea_ossl.h"

@implementation BlorPasswordRetriever

- (id)initWithBlor:(NSString*)blorPath {
	self = [super init];
	if (self) {
		path = [blorPath retain];
		
		couldRetrieveFromKeychain = NO;
		
		//read hash (first 20 bytes) of file
		NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
		hashData = [[handle readDataOfLength:20] retain];
		
		[handle closeFile];
		
		if (!hashData || [hashData length] < 20) {
			[self release];
			return nil;
		}
	}
	
	return self;
}

- (IBAction)cancelAction:(id)sender {
	[NSApp stopModalWithCode:0];
	[window close];
	
	if (![[GlobalPrefs defaultPrefs] triedToImportBlor]) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:NSLocalizedString(@"Note Importing Cancelled", nil)];
		[alert setInformativeText:NSLocalizedString(@"You can import your old notes at any time by choosing quotemarkImport...quotemark from the quotemarkNotequotemark menu and selecting your NotationalDatabase.blor file.", nil)];
		[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
		[alert runModal];
	}
}

- (IBAction)importAction:(id)sender {
	//check pw against hash and defaultCStringEncoding
	
	NSData *passData = [[passphraseField stringValue] dataUsingEncoding:[NSString defaultCStringEncoding] allowLossyConversion:NO];
	
	if ([[passData SHA1Digest] isEqualToData:hashData]) {
		
		[NSApp stopModalWithCode:1];
		[window close];
		
	} else {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:NSLocalizedString(@"Sorry, you entered an incorrect passphrase.", nil)];
		[alert setInformativeText:NSLocalizedString(@"Please try again.", nil)];
		[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
		[alert beginSheetModalForWindow:window completionHandler:nil];
	}	
	
}

- (NSData*)validPasswordHashData {
	
	[originalPasswordString release];
	originalPasswordString = nil;
		
	//run dialog and grab PW
	
	if (!window) {
		NSArray *topLevelObjects = nil;
		if (![[NSBundle mainBundle] loadNibNamed:@"BlorPasswordRetriever" owner:self topLevelObjects:&topLevelObjects])  {
			NSLog(@"Failed to load BlorPasswordRetriever.nib");
			NSBeep();
			return NULL;
		}
		[blorTopLevelObjects release];
		blorTopLevelObjects = [topLevelObjects retain];
	}
	
	[helpStringField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Please enter the passphrase to import old notes at %@.",nil), 
		[path stringByAbbreviatingWithTildeInPath]]];
	
	NSInteger result = [NSApp runModalForWindow:window];
	
	NSString *passwordString = [passphraseField stringValue];
	NSData *passwordData = [passwordString dataUsingEncoding:[NSString defaultCStringEncoding] allowLossyConversion:NO];
	
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
	[blorTopLevelObjects release];
	
	[super dealloc];
}

@end


@implementation BlorNoteEnumerator

- (id)initWithBlor:(NSString*)blorPath passwordHashData:(NSData*)passwordHashData {
	self = [super init];
	if (self) {
		path = [blorPath retain];
		
		if (!(keyData = [passwordHashData retain])) {
			[self release];
			return nil;
		}
		
		if (!(blorData = [[NSMutableData dataWithContentsOfFile:path] retain])) {
			[self release];
			return nil;
		}
			
		if ([blorData length] < 28) {
			NSLog(@"read data is too small (%lu) to hold any notes!", (unsigned long)[blorData length]);
			[self release];
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
        NSLog(@"Attempted to read %lu bytes past the length of the blor!", (unsigned long)(((n) + currentByteOffset) - [blorData length]));\
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
	[attributedBody addAttributesForMarkdownHeadingLinesInRange:NSMakeRange(0, [attributedBody length])];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:attributedBody title:titleString delegate:nil format:SingleDatabaseFormat labels:nil];

	[bodyString release];
	[attributedBody release];
	[titleString release];
	
	if (note) successfullyReadNoteCount++;
	
	return [note autorelease];
}

@end
