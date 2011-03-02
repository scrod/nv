//
//  BlorPasswordRetriever.h
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