//
//  BlorPasswordRetriever.h
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
