/*
 *  SynchronizedNoteProtocol.h
 *  Notation
 *
 *  Created by Zachary Schneirov on 4/22/06.
 *  Copyright 2006 Zachary Schneirov. All rights reserved.
 *
 */

@protocol SynchronizedNote <NSCoding, NSObject>

- (CFUUIDBytes *)uniqueNoteIDBytes;
- (NSDictionary *)syncServicesMD;
//need methods to modify parts of syncServicesMD
- (unsigned int)logSequenceNumber;
- (void)incrementLSN;
- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj;

- (void)setSyncObjectAndKeyMD:(NSDictionary*)aDict forService:(NSString*)serviceName;
- (void)removeAllSyncMDForService:(NSString*)serviceName;


@end
