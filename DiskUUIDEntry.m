//
//  DiskUUIDEntry.m
//  Notation
//
//  Created by Zachary Schneirov on 1/17/11.

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


#import "DiskUUIDEntry.h"


@implementation DiskUUIDEntry

- (id)initWithUUIDRef:(CFUUIDRef)aUUIDRef {
	if ([super init]) {
		NSAssert(aUUIDRef != nil, @"need a real UUID");
		uuidRef = CFRetain(aUUIDRef);
		lastAccessed = [[NSDate date] retain];
	}
	return self;
}

- (void)dealloc {

	[lastAccessed release];
	CFRelease(uuidRef);
	[super dealloc];
}
- (void)encodeWithCoder:(NSCoder *)coder {
	NSAssert([coder allowsKeyedCoding], @"keyed-encoding only!");
	
	[coder encodeObject:lastAccessed forKey:VAR_STR(lastAccessed)];
	
	CFUUIDBytes bytes = CFUUIDGetUUIDBytes(uuidRef);
	[coder encodeBytes:(const uint8_t *)&bytes length:sizeof(CFUUIDBytes) forKey:VAR_STR(uuidRef)];

}
- (id)initWithCoder:(NSCoder*)decoder {
	NSAssert([decoder allowsKeyedCoding], @"keyed-decoding only!");
	
    if ([super init]) {

		lastAccessed = [[decoder decodeObjectForKey:VAR_STR(lastAccessed)] retain];
		
		NSUInteger decodedByteCount = 0;
		const uint8_t *bytes = [decoder decodeBytesForKey:VAR_STR(uuidRef) returnedLength:&decodedByteCount];
		if (bytes && decodedByteCount)  {
			uuidRef = CFUUIDCreateFromUUIDBytes(NULL, *(CFUUIDBytes*)bytes);
		}
		
		if (!uuidRef) return nil;
	}
	return self;
}

- (void)see {
	[lastAccessed release];
	lastAccessed = [[NSDate date] retain];
}

- (CFUUIDRef)uuidRef {
	return uuidRef;
}

- (NSDate*)lastAccessed {
	return lastAccessed;
}

- (NSString*)description {
	return [NSString stringWithFormat:@"DiskUUIDEntry(%@, %@)", lastAccessed, [(id)CFUUIDCreateString(NULL, uuidRef) autorelease]];
}

- (NSUInteger)hash {
	return CFHash(uuidRef);
}
- (BOOL)isEqual:(id)otherEntry {
	return CFEqual(uuidRef, [otherEntry uuidRef]);
}

@end
