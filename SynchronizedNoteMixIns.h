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


//used by DeletedNoteObject and NoteObject

- (void)setSyncObjectAndKeyMD:(NSDictionary*)aDict forService:(NSString*)serviceName {
	NSMutableDictionary *dict = [syncServicesMD objectForKey:serviceName];
	if (!dict) {
		dict = [[NSMutableDictionary alloc] initWithDictionary:aDict];
		if (!syncServicesMD) syncServicesMD = [[NSMutableDictionary alloc] init];
		[syncServicesMD setObject:dict forKey:serviceName];
		[dict release];
	} else {
		[dict addEntriesFromDictionary:aDict];
	}
}
- (void)removeAllSyncMDForService:(NSString*)serviceName {
	[syncServicesMD removeObjectForKey:serviceName];
}
//- (void)removeKey:(NSString*)aKey forService:(NSString*)serviceName {
//	[[syncServicesMD objectForKey:serviceName] removeObjectForKey:aKey];
//}

- (CFUUIDBytes *)uniqueNoteIDBytes {
    return &uniqueNoteIDBytes;
}
- (NSDictionary*)syncServicesMD {
    return syncServicesMD;
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

- (NSUInteger)hash {
	//XOR successive native-WORDs of CFUUIDBytes
	NSUInteger finalHash = 0;
	NSUInteger i, *noteIDBytesPtr = (NSUInteger *)&uniqueNoteIDBytes;
	for (i = 0; i<sizeof(CFUUIDBytes) / sizeof(NSUInteger); i++) {
		finalHash ^= *noteIDBytesPtr++;
	}
	return finalHash;
}
- (BOOL)isEqual:(id)otherNote {
	CFUUIDBytes *otherBytes = [(id <SynchronizedNote>)otherNote uniqueNoteIDBytes];
	return memcmp(otherBytes, &uniqueNoteIDBytes, sizeof(CFUUIDBytes)) == 0;
}
