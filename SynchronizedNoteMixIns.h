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
