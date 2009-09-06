//
//  BlorPasswordRetriever.h
//  Notation
//
//  Created by Zachary Schneirov on 12/13/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface BlorPasswordRetriever : NSObject {
	IBOutlet NSTextField *helpStringField, *passphraseField;
	IBOutlet NSButton *importButton, *cancelButton;
	IBOutlet NSWindow *window;
	
	BOOL couldRetrieveFromKeychain;
	NSString *path, *originalPasswordString;
	NSData *hashData;
}

- (id)initWithBlor:(NSString*)blorPath;

- (IBAction)cancelAction:(id)sender;
- (IBAction)importAction:(id)sender;

//get from the keychain or from the user, verifying with the SHA-1 hash in the .blor file
- (NSData*)keychainPasswordData;
- (NSData*)validPasswordHashData;
- (NSString*)originalPasswordString;

- (BOOL)canRetrieveFromKeychain;

@end

@interface BlorNoteEnumerator : NSObject {
	NSString *path;
	NSMutableData *blorData;
	NSData *keyData;
	unsigned int currentByteOffset, suspectedNoteCount, successfullyReadNoteCount;
}

- (id)initWithBlor:(NSString*)blorPath passwordHashData:(NSData*)passwordHashData;
- (unsigned int)suspectedNoteCount;
- (void)decryptNextBytesOfLength:(long)length;
- (id)nextNote;

@end