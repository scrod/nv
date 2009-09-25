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
- (unsigned int)serverModifiedDate;
- (unsigned int)logSequenceNumber;
- (void)incrementLSN;
- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj;

@end
