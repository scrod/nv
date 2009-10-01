//
//  WALController.h
//  Notation
//
//  Created by Zachary Schneirov on 2/5/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

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
