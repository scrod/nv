//
//  WALController.m
//  Notation
//
//  Created by Zachary Schneirov on 2/5/06.

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


#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#import "NSData_transformations.h"
#import "WALController.h"
#import "DeletedNoteObject.h"
#import "NSCollection_utils.h"
#import "NSString_NV.h"

//file descriptor based for lower level access

//also used as an ad-hoc lock file;
//if it's removed, assume another application did it
//so serialize notes to database file and quit
//if the other app already recovered the journal and rewrote the database file then it won't matter
//if it didn't, well at least the notes have been saved

@implementation WALController

- (id)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key {
    if ([super init]) {
		logFD = -1;
		
		char filename[] = "Interim Note-Changes";
		size_t newPathLength = sizeof(filename) + strlen(path) + 2;
		
		journalFile = (char*)malloc(newPathLength);
		strlcpy(journalFile, path, newPathLength);
		strlcat(journalFile, "/", newPathLength);
		strlcat(journalFile, filename, newPathLength);
		
		//for simplicity's sake the log file is always compressed and encrypted with the key for the current database
		//if the database has no encryption, it should have passed some constant known key to us instead
		logSessionKey = [key retain];
		
    }
    return self;
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}

//called frequently--each time the app comes to the foreground?
- (BOOL)logFileStillExists {
    struct stat sb;
    
    //but really we shouldn't just fstat the fd because the file shouldn't be renamed or moved, either
    //on the other hand, what if another app deleted and re-created it? then any changes would be lost upon closing the fd
    if (fstat(logFD, &sb) < 0) {
	NSLog(@"logFileStillExists: fstat error: %s", strerror(errno));
	
	return NO;
    }
    
    return (sb.st_nlink > 0);
}

- (BOOL)destroyLogFile {

	journalFile = (char*)realloc(journalFile, 4096 * sizeof(char));
    intptr_t pathIntPtr = (intptr_t)journalFile;
	
	//get current path of file descriptor in case the directory was moved
	if (fcntl(logFD, F_GETPATH, pathIntPtr) < 0) {
		NSLog(@"destroyLogFile: fcntl F_GETPATH error: %s", strerror(errno));
	}
	
	if (close(logFD) < 0) {
		NSLog(@"destroyLogFile: close error: %s:", strerror(errno));
	}
	
	if (unlink(journalFile) < 0) {
		NSLog(@"destroyLogFile: unlink error: %s", strerror(errno));
		return NO;
	}
    return YES;
}

- (void)dealloc {
	if (journalFile)
		free(journalFile);
	[logSessionKey release];
	
	[super dealloc];
}

@end

@implementation WALStorageController
//appends a compressed stream of serialized notes

//general operation when writing the serialized database:

//log file is flushed to disk with synchronize
//log file is closed

//notes are serialized and fs-exchanged

//if these operations are all successful, log file is removed


- (id)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key {
    if ([super initWithParentFSRep:path encryptionKey:key]) {
	
	//we could make parent dir writable just in case, but that might be a security hazard depending on ownership
	//chmod(path, S_IRWXU | S_IRWXG | S_IRWXO);
	
	//attempt to open/create the file exclusively with write-only and append access
	
	if ((logFD = open(journalFile, O_CREAT | O_EXCL | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)) < 0) {
	    //if this fails, the file probably still exists, or we don't have write permission
	    //either way, we shouldn't continue
	    
	    NSLog(@"WALStorageController: open error for file %s: %s", journalFile, strerror(errno));
	    
	    return nil;
	}
	if (fcntl(logFD, F_NOCACHE, 1) < 0) {
		NSLog(@"Unable to disable disk caching for writing: %s", strerror(errno));
	}
		
	//this will grow as necessary
	unwrittenData = [[NSMutableData dataWithCapacity:16] retain];
	
	//initialize the compression
		compressionStream.total_in = 0;
		compressionStream.total_out = 0;
		compressionStream.zalloc = Z_NULL;
		compressionStream.zfree = Z_NULL;
		compressionStream.opaque = Z_NULL;

		if (deflateInit2(&compressionStream, 5, Z_DEFLATED, MAX_WBITS, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY) != Z_OK) {
			NSLog(@"deflateInit2 returned error: %s", compressionStream.msg);
			return nil;
		}
		
    }
    
    return self;
}

- (BOOL)writeNoteObject:(id<SynchronizedNote>)aNoteObject {
	//this method serializes a note object, encrypts it, and writes it to the log
    NSMutableData *noteData = [NSMutableData data];
	NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:noteData] autorelease];
	[archiver encodeObject:aNoteObject forKey:@"aNote"];
	[archiver finishEncoding];
	
    if ([noteData length])
		return [self _encryptAndWriteData:noteData];
    
    return NO;
}

- (BOOL)writeEstablishedNote:(id<SynchronizedNote>)aNoteObject {
	[aNoteObject incrementLSN];
	
	return [self writeNoteObject:aNoteObject];
}

- (BOOL)writeRemovalForNote:(id<SynchronizedNote>)aNoteObject {
	//increment the original note's LSN to ensure it's stored in the final DB
    [aNoteObject incrementLSN];
    
    //construct a "removal object" for this note with some identifying information
	DeletedNoteObject *removedNote = [[[DeletedNoteObject alloc] initWithExistingObject:aNoteObject] autorelease];
    
	return [self writeNoteObject:removedNote];	
}

- (void)writeNoteObjects:(NSArray*)notes {
	//assume that the LSNs have been incremented already if they needed to be
	NSUInteger i;
    for (i=0; i<[notes count]; i++) {
		[self writeNoteObject:[notes objectAtIndex:i]];
	}
}

- (BOOL)_attemptToWriteUnwrittenData {
    ssize_t bytesWritten = 0;
    
    //attempt to write any buffered data
    if ([unwrittenData length] > 0) {
		if ((bytesWritten = write(logFD, [unwrittenData bytes], [unwrittenData length])) > 0) {
			//shift bytes backward and shrink buffer if any data could be written
			void *bytes = [unwrittenData mutableBytes];
			size_t newLength = [unwrittenData length] - bytesWritten;
			
			if (newLength > 0)
				memmove(bytes, bytes + bytesWritten, newLength);
			[unwrittenData setLength:newLength];
		} else {
			NSLog(@"Unable to empty out unwritten data to journal %s: %s", journalFile, strerror(errno));
		}
    }
    
    return ([unwrittenData length] == 0);
}

- (BOOL)_encryptAndWriteData:(NSMutableData*)data {
    WALRecordHeader record = {{0}};
	
	record.originalDataLength = CFSwapInt32HostToBig([data length]);
	
	size_t compressedDataBufferSize = [data length] + (( [data length] + 99 ) / 100 ) + 12;
	Bytef *compressedDataBuffer = (Bytef *)malloc(compressedDataBufferSize);
	
    //adapt nsdata to compression stream
	compressionStream.next_in = (Bytef*)[data bytes];
	compressionStream.avail_in = [data length];
	compressionStream.next_out = compressedDataBuffer;
	compressionStream.avail_out = compressedDataBufferSize;
	compressionStream.data_type = Z_BINARY;
	
	uLong previousOut = compressionStream.total_out;
	/* Perform the compression here. */
	int deflateResult = deflate(&compressionStream, Z_SYNC_FLUSH);
	/*Find the total size of the resulting compressed data. */
	uLong zlibAfterBufLen = compressionStream.total_out - previousOut;

	if (deflateResult != Z_OK) {
		NSLog(@"zlib deflation error: %s\n", compressionStream.msg);
		return NO;
	}
	if (zlibAfterBufLen > compressedDataBufferSize) {
		NSLog(@"zlibAfterBufLen is larger than the allocated compressed buffer!");
		return NO;
	}
	
	[data setLength:zlibAfterBufLen];
	memcpy([data mutableBytes], compressedDataBuffer, zlibAfterBufLen);
	free(compressedDataBuffer);
    
	//encrypt nsdata here using record salt and record key
	NSData *recordSalt = [NSData randomDataOfLength:RECORD_SALT_LEN];
	NSData *recordKey = [logSessionKey derivedKeyOfLength:[logSessionKey length] salt:recordSalt iterations:1];
	
	if (![data encryptAESDataWithKey:recordKey iv:[recordSalt subdataWithRange:NSMakeRange(0, 16)]]) {
		NSLog(@"Couldn't encrypt WAL record data!");
		return NO;
	}
	
	//write length, checksum of data, record salt, then data itself
    //assert(sizeof(record) == sizeof(record.recordBuffer));
    
    record.dataLength = CFSwapInt32HostToBig([data length]);
    record.checksum = CFSwapInt32HostToBig([data CRC32]);
	memcpy(record.saltBuffer, [recordSalt bytes], RECORD_SALT_LEN);
    
    //pack all the data to avoid multiple writes
    size_t dataChunkSize = sizeof(record) + [data length];
    char *dataChunk = (char*)malloc(dataChunkSize);
    
    memcpy(dataChunk, record.recordBuffer, sizeof(record.recordBuffer));
    memcpy(dataChunk + sizeof(record.recordBuffer), [data bytes], [data length]);
    
    ssize_t bytesWritten = 0;
    
    //attempt to write any buffered data first
    if ([self _attemptToWriteUnwrittenData]) {
		//always append data in the right order; if there is old buffered data, then the new data is buffered until that is empty
		//otherwise the new data is appended immediately
		
		bytesWritten = write(logFD, dataChunk, dataChunkSize);
    }
    
    if (bytesWritten < 0) {
		NSLog(@"Unable to write new data to journal %s: %s", journalFile, strerror(errno));
		bytesWritten = 0;
    }
	
    if ((size_t)bytesWritten < dataChunkSize) {
		//buffer any remaining data that we were not able to write (in case the disk was full, for example)
		[unwrittenData appendBytes:dataChunk + bytesWritten length:(dataChunkSize - bytesWritten)];
    }
    
    free(dataChunk);
    
    return ((size_t)bytesWritten == dataChunkSize);
}

- (BOOL)synchronize {
    
    BOOL flushedUnwritten = [self _attemptToWriteUnwrittenData];
    
    //F_FULLFSYNC is probably overkill
    if (fsync(logFD)) {
	NSLog(@"synchronize WAL: fsync error: %s", strerror(errno));
	return NO;
    }
    
    return flushedUnwritten;
}

- (void)dealloc {
    [unwrittenData release];
    [super dealloc];
}

@end

@implementation WALRecoveryController

//record structure:
//int size
//int CRC32
//bytes from NSData

//general operation for recovering log:
//if walstoragecontroller couldn't be initialized, then the file probably already exists
//so try to initialize it here
//if that works, call recoverNextObject sequentially until it returns nil

//re-serialize all the (now-recovered) notes to database

//if that works, then remove the log file

- (id)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key {
    if ([super initWithParentFSRep:path encryptionKey:key]) {
	fileLength = totalBytesRead = 0;
	
	//make file readable just in case
	chmod(journalFile, S_IRUSR);
	
	//attempt to open file read-only
	if ((logFD = open(journalFile, O_EXCL | O_RDONLY)) < 0) {
	    NSLog(@"WALRecoveryController: open error for file %s: %s", journalFile, strerror(errno));
	    return nil;
	}
	
	struct stat sb;
	if (fstat(logFD, &sb) < 0) {
	    NSLog(@"WALRecoveryController: fstat error for file %s: %s", journalFile, strerror(errno));
	    return nil;
	}
	
	if (S_ISDIR(sb.st_mode)) {
	    NSLog(@"WALRecoveryController: log file is actually a directory! Don't play games with me!");
	    return nil;
	}
	
	fileLength = sb.st_size;
	
	//initialize decompression context
	compressionStream.total_in = 0;
	compressionStream.total_out = 0;
	compressionStream.zalloc = Z_NULL;
	compressionStream.zfree = Z_NULL;
	compressionStream.opaque = Z_NULL;
	
	if (inflateInit2(&compressionStream, MAX_WBITS) != Z_OK) {
		NSLog(@"inflateInit2 error: %s", compressionStream.msg);
		return nil;
	}
	
    }
    return self;
}

//log enumerating method
- (id <SynchronizedNote>)recoverNextObject {
    WALRecordHeader record = {{0}};
    
    //attempt to read size of log record and checksum
    //if it's smaller than the remaining bytes to read
    //allocate enough memory, try to read data in, and checksum it
    //if checksum matches, attempt to deserialize
    //if deserialization was successful, then return a new object!
    
    //if any of these fail, return nil
	
    //adapt reads to read from decompression stream
    
    ssize_t readBytes = read(logFD, &record, sizeof(WALRecordHeader));
    totalBytesRead += MAX(0, readBytes);
	
    if (readBytes < (int)sizeof(WALRecordHeader)) {
		NSLog(@"recoverNextObject can't even read (entire) log record header: %s", strerror(errno));
		return nil;
    }
	
	record.originalDataLength = CFSwapInt32BigToHost(record.originalDataLength);
	record.dataLength = CFSwapInt32BigToHost(record.dataLength);
	record.checksum = CFSwapInt32BigToHost(record.checksum);
    
    if (record.dataLength > fileLength - totalBytesRead) {
		NSLog(@"recoverNextObject can't continue because the size of this record is larger than the rest of the file!");
		return nil;
    }
    
    char *presumablySerializedBytes = (char*)malloc(record.dataLength);
    
    readBytes = read(logFD, presumablySerializedBytes, record.dataLength);
    totalBytesRead += MAX(0, readBytes);
    
    if (readBytes < (int)record.dataLength) {
		NSLog(@"recoverNextObject can't read all serialized bytes: %s", strerror(errno));
		free(presumablySerializedBytes);
		return nil;
    }
    
    NSMutableData *presumablySerializedData = [[NSMutableData alloc] initWithBytesNoCopy:presumablySerializedBytes 
																				  length:record.dataLength freeWhenDone:YES];
    if ([presumablySerializedData CRC32] != record.checksum) {
		NSLog(@"recoverNextObject: checksum of read data does not match that of record header");
		[presumablySerializedData release];
		return nil;
    }
	    
    //attempt to decrypt using record key based on record salt and log session key
	NSData *recordSalt = [NSData dataWithBytesNoCopy:record.saltBuffer length:RECORD_SALT_LEN freeWhenDone:NO];
	NSData *recordKey = [logSessionKey derivedKeyOfLength:[logSessionKey length] salt:recordSalt iterations:1];
	
	if (!([presumablySerializedData decryptAESDataWithKey:recordKey iv:[recordSalt subdataWithRange:NSMakeRange(0, 16)]])) {
		NSLog(@"Record decryption failed!");
		return nil;
	}
	
	//decompress here
	Bytef *uncompressedDataBuffer = (Bytef *)malloc(record.originalDataLength);
	
	compressionStream.avail_in = [presumablySerializedData length];
	compressionStream.next_in = (Bytef*)[presumablySerializedData bytes];
	compressionStream.avail_out = record.originalDataLength;
	compressionStream.next_out = uncompressedDataBuffer;
	compressionStream.data_type = Z_BINARY;
	
	int inflateResult = inflate(&compressionStream, Z_SYNC_FLUSH);
	if (inflateResult == Z_STREAM_ERROR) {
		NSLog(@"zlib inflate error: %s", compressionStream.msg);
		return nil;
	}
	if (inflateResult == Z_NEED_DICT || inflateResult == Z_DATA_ERROR || 
		inflateResult == Z_MEM_ERROR) {
		NSLog(@"err: inflateResult = %d", inflateResult);
		return nil;
	}
	
	if (compressionStream.avail_out != 0) {
		NSLog(@"recoverNextObject: compressionStream.avail_out(%d) != 0", compressionStream.avail_out);
		return nil;
	}
	
	[presumablySerializedData setLength:record.originalDataLength];
	memcpy([presumablySerializedData mutableBytes], uncompressedDataBuffer, record.originalDataLength);
	free(uncompressedDataBuffer);
	
    
    id <SynchronizedNote> object = nil;
	@try {
		NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:presumablySerializedData];
		object = [unarchiver decodeObjectForKey:@"aNote"];
		[unarchiver release];	
    } @catch (NSException *e) {
		NSLog(@"recoverNextObject got an exception while unarchiving object: %@; returning NSNull to skip", [e reason]);
		object = (id<SynchronizedNote>)[NSNull null];
    }
    
    [presumablySerializedData release];
    
    return object;
}

static CFStringRef SynchronizedNoteKeyDescription(const void *value) {

	return value ? (CFStringRef)[NSString uuidStringWithBytes:*(CFUUIDBytes*)value] : NULL;
}
static CFHashCode SynchronizedNoteHash(const void * o) {
	
	return CFHashBytes(o, sizeof(CFUUIDBytes));
}
static Boolean SynchronizedNoteIsEqual(const void *o, const void *p) {
	
	return (!memcmp((CFUUIDBytes*)o, (CFUUIDBytes*)p, sizeof(CFUUIDBytes)));
}

//we keep a table of the newest recovered notes, as any changed notes will almost certainly be written multiple times
//throw away objects with LSNs lower than the current highest one for each UUID
//and when recovery cannot progress any further, only the newest objects will be exchanged

- (NSDictionary*)recoveredNotes {
    id <SynchronizedNote> obj = nil;
	CFUUIDBytes *objUUIDBytes = NULL;
    
    CFDictionaryKeyCallBacks keyCallbacks = kCFTypeDictionaryKeyCallBacks;
    keyCallbacks.equal = SynchronizedNoteIsEqual;
    keyCallbacks.hash = SynchronizedNoteHash;
	keyCallbacks.copyDescription = SynchronizedNoteKeyDescription;
	keyCallbacks.retain = NULL;
	keyCallbacks.release = NULL;
    
    CFMutableDictionaryRef recoveredNotes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &keyCallbacks, &kCFTypeDictionaryValueCallBacks);
    
    do {
		if ((obj = [self recoverNextObject])) {
			
			if ([obj conformsToProtocol:@protocol(SynchronizedNote)]) {
				objUUIDBytes = [obj uniqueNoteIDBytes];
				id <SynchronizedNote> foundNote = nil;
				
				//if the note already exists, then insert this note only if it's newer, and always insert it if it doesn't exist
				if (CFDictionaryGetValueIfPresent(recoveredNotes, (const void *)objUUIDBytes, (const void **)&foundNote)) {
					
					//note is already here, overwrite it only if our LSN is greater or equal
					if (foundNote && ![foundNote youngerThanLogObject:obj])
						continue;
				}
				CFDictionarySetValue(recoveredNotes, (const void *)objUUIDBytes, (const void *)obj);
			} else {
				NSLog(@"object of class %@ recovered that doesn't conform to SynchronizedNote protocol", [(NSObject*)obj className]);
			}
		}
    } while (obj); //|| this note failed because of a deserialization problem, but everything else was fine
    
    
	return [(NSDictionary*)recoveredNotes autorelease];
}

@end
