//
//  DeletedNoteObject.m
//  Notation
//
//  Created by Zachary Schneirov on 4/16/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import "DeletedNoteObject.h"

@implementation DeletedNoteObject

- (id)initWithExistingObject:(id<SynchronizedNote>)note {
    if ([super init]) {
		CFUUIDBytes *bytes = [note uniqueNoteIDBytes];
		uniqueNoteIDBytes = *bytes;
		serverModifiedTime = [note serverModifiedDate];
		logSequenceNumber = [note logSequenceNumber];	
    }
    return self;
}

- (id)initWithCoder:(NSCoder*)decoder {
    if ([super init]) {
		
		if ([decoder allowsKeyedCoding]) {
			NSUInteger decodedByteCount;
			const uint8_t *decodedBytes = [decoder decodeBytesForKey:VAR_STR(uniqueNoteIDBytes) returnedLength:&decodedByteCount];
			memcpy(&uniqueNoteIDBytes, decodedBytes, MIN(decodedByteCount, sizeof(CFUUIDBytes)));
			serverModifiedTime = [decoder decodeInt32ForKey:VAR_STR(serverModifiedTime)];
			logSequenceNumber = [decoder decodeInt32ForKey:VAR_STR(logSequenceNumber)];
		} else {
			[decoder decodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
		}
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	
	if ([coder allowsKeyedCoding]) {
		[coder encodeBytes:(const uint8_t *)&uniqueNoteIDBytes length:sizeof(CFUUIDBytes) forKey:VAR_STR(uniqueNoteIDBytes)];
		[coder encodeInt32:serverModifiedTime forKey:VAR_STR(serverModifiedTime)];
		[coder encodeInt32:logSequenceNumber forKey:VAR_STR(logSequenceNumber)];
	} else {
		[coder encodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
		[coder encodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
		[coder encodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
	}
}

- (CFUUIDBytes *)uniqueNoteIDBytes {
    return &uniqueNoteIDBytes;
}
- (unsigned int)serverModifiedDate {
    return serverModifiedTime;
}
- (unsigned int)logSequenceNumber {
    return logSequenceNumber;
}
- (void)incrementLSN {
    logSequenceNumber++;
}
- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj {
	return [self logSequenceNumber] < [obj logSequenceNumber];
}
//TODO: need hash and isEquals methods here; for hashing, XOR successive native-WORDs of CFUUIDBytes?
//refactor serverModifiedDate into object? dict? to contain stateful data for more than one service, including other identifiers

@end
