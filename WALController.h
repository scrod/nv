//
//  WALController.h
//  Notation
//
//  Created by Zachary Schneirov on 2/5/06.

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
#import "SynchronizedNoteProtocol.h"
#include <sys/types.h>
#include <zlib.h>

#define RECORD_SALT_LEN 32

//each note will have its own key--the "LogSessionKey" salt of master key + per-record salt
typedef union {
    struct {
		u_int32_t originalDataLength;
		u_int32_t dataLength;
		u_int32_t checksum;
		char saltBuffer[RECORD_SALT_LEN];
	};
	char recordBuffer[(sizeof(u_int32_t) * 3) + RECORD_SALT_LEN];
} WALRecordHeader;

@interface WALController : NSObject {
	int logFD;
	char *journalFile;
	NSData *logSessionKey;
	id delegate;
	
	z_stream compressionStream;
}

- (id)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key;
- (id)delegate;
- (void)setDelegate:(id)aDelegate;
- (BOOL)logFileStillExists;
- (BOOL)destroyLogFile;

@end

@interface WALStorageController : WALController {
    NSMutableData *unwrittenData;
}
- (id)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key;
- (BOOL)writeEstablishedNote:(id<SynchronizedNote>)aNoteObject;
- (BOOL)writeRemovalForNote:(id<SynchronizedNote>)aNoteObject;
- (BOOL)writeNoteObject:(id<SynchronizedNote>)aNoteObject;
- (void)writeNoteObjects:(NSArray*)notes;
- (BOOL)_attemptToWriteUnwrittenData;
- (BOOL)_encryptAndWriteData:(NSMutableData*)data;
- (BOOL)synchronize;

@end



@interface WALRecoveryController : WALController {
    off_t fileLength, totalBytesRead;
    //to ensure we don't mistakenly allocate more memory
    //than there exists data in what we have yet to read
}

- (id)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key;
- (id <SynchronizedNote>)recoverNextObject;
- (NSDictionary*)recoveredNotes;

@end
