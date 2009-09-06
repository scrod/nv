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
		//needs a case for nskeyedarchiver as well; will CFUUIDBytes just be nsdata?
		[decoder decodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
		[decoder decodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
		[decoder decodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
    [coder encodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
    [coder encodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
    
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

@end
