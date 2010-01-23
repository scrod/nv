
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
