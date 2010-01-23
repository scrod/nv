//
//  DeletedNoteObject.h
//  Notation
//
//  Created by Zachary Schneirov on 4/16/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "SynchronizedNoteProtocol.h"

//archived instances of this class are stored in the journal and on the server
//the sole purpose of these objects is to aid in the removal of existing notes

@interface DeletedNoteObject : NSObject <NSCoding, SynchronizedNote> {
    unsigned int logSequenceNumber;
    CFUUIDBytes uniqueNoteIDBytes;
    NSMutableDictionary *syncServicesMD;
}

+ (id)deletedNoteWithNote:(id <SynchronizedNote>)aNote;
- (id)initWithExistingObject:(id<SynchronizedNote>)note;
- (CFUUIDBytes *)uniqueNoteIDBytes;
- (NSDictionary *)syncServicesMD;
- (unsigned int)logSequenceNumber;
- (void)incrementLSN;
- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj;

- (void)removeAllSyncMDForService:(NSString*)serviceName;

@end
