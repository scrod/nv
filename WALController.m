//
//  WALController.m
//  Notation
//
//  Created by Zachary Schneirov on 2/5/06.

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


#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/file.h>
#import "NSData_transformations.h"
#import "WALController.h"
#import "DeletedNoteObject.h"
#import "NSCollection_utils.h"
#import "NSString_NV.h"
#import "NVRootedDirectory_Private.h"

/*
 * Write-ahead log theory of operation
 * -----------------------------------
 * "Interim Note-Changes" is both the durability journal and the per-database
 * ownership lock.  A writer creates it exclusively, takes flock(), and appends
 * note versions to one continuous zlib stream.  Each append is independently
 * archived and encrypted, then framed with its uncompressed length, encrypted
 * length, checksum, and salt.  -synchronize drains short writes and barrier-syncs
 * the journal before the corresponding database write can proceed.
 * Once zlib advances, a failure to finish that record permanently stops this
 * writer; later records would otherwise depend on compressed bytes never saved.
 *
 * A recovery reader opens the existing file and takes the same lock before it
 * scans anything.  It captures the file length so a header or payload which
 * ends exactly at that captured boundary can be treated as a benign interrupted
 * final append.  Records share zlib state: an archive/type/declared-length error
 * may be skipped only after all of that record's compressed bytes have been
 * consumed.  Checksum, decryption, read, allocation, or zlib errors stop the
 * scan because the stream position can no longer be trusted.
 *
 * Recovery always returns the valid prefix (coalesced to the newest LSN for
 * each note UUID) plus an "incomplete" indication.  This file does not decide
 * which database receives those notes or when the old journal is retired;
 * StartupRecovery owns that policy and retains this reader, and therefore its
 * flock(), until the journal has been safely preserved or replaced.
 */

#define RECORD_SALT_LEN 32

//each note will have its own key--the "LogSessionKey" salt of master key + per-record salt
typedef union {
    struct {
		u_int32_t originalDataLength;
		u_int32_t dataLength;
		u_int32_t checksum;
		char saltBuffer[RECORD_SALT_LEN];
	};
	char recordBuffer[(sizeof(u_int32_t) * 3) + RECORD_SALT_LEN];
} WALRecordHeader;

NSString * const NVJournalFilename = @"Interim Note-Changes";

typedef NS_ENUM(NSUInteger, WALRecordRecoveryResult) {
	WALRecordRecovered, //object and shared compression state are both valid
	WALRecordSkipped,   //record is unusable, but the next record can be decoded
	WALRecoveryEnded,   //clean EOF or an interrupted final append
	WALRecoveryStopped  //later records cannot be decoded safely
};

static ssize_t NVReadWALBytes(int fileDescriptor, void *buffer, size_t length,
	int *readError) {
	/* A regular-file read may legally return short before EOF.  Fill the caller's
	 * requested region unless read reaches EOF or produces a real error; the
	 * caller compares the result with the captured journal boundary. */
	size_t total = 0;
	if (readError) *readError = 0;
	while (total < length) {
		ssize_t amount = read(fileDescriptor, (uint8_t*)buffer + total, length - total);
		if (amount > 0) {
			total += (size_t)amount;
			continue;
		}
		if (amount < 0 && errno == EINTR) continue;
		if (amount < 0 && readError) *readError = errno;
		break;
	}
	return (ssize_t)total;
}

@interface WALController ()
- (id)initWithRootedDirectory:(NVRootedDirectory*)root encryptionKey:(NSData*)key;
- (int)_logFileDescriptor;
- (int)_flockJournalFile;
- (BOOL)_acquireJournalLock;
@end

@interface WALStorageController ()
- (BOOL)writeNoteObject:(id<SynchronizedNote>)aNoteObject;
- (BOOL)_attemptToWriteUnwrittenData;
- (BOOL)_encryptAndWriteData:(NSMutableData*)data;
@end

@interface WALRecoveryController ()
- (WALRecordRecoveryResult)recoverNextObject:(id<SynchronizedNote>*)recoveredObject;
@end

/*
 CFHashBytes from http://www.opensource.apple.com/source/CF/CF-1153.18/CFUtilities.c
 */
#define ELF_STEP(B) T1 = (H << 4) + B; T2 = T1 & 0xF0000000; if (T2) T1 ^= (T2 >> 24); T1 &= (~T2); H = T1;

static CFHashCode CFHashBytes(const uint8_t *bytes, CFIndex length) {
    /* The ELF hash algorithm, used in the ELF object file format */
    UInt32 H = 0, T1, T2;
    SInt32 rem = (SInt32)length;
    while (3 < rem) {
        ELF_STEP(bytes[length - rem]);
        ELF_STEP(bytes[length - rem + 1]);
        ELF_STEP(bytes[length - rem + 2]);
        ELF_STEP(bytes[length - rem + 3]);
        rem -= 4;
    }
    switch (rem) {
        case 3:  ELF_STEP(bytes[length - 3]);
        case 2:  ELF_STEP(bytes[length - 2]);
        case 1:  ELF_STEP(bytes[length - 1]);
        case 0:  ;
    }
    return H;
}

#undef ELF_STEP

@implementation WALController

- (int)_logFileDescriptor { return logFileHandle ? [logFileHandle fileDescriptor] : -1; }

- (void)_closeLogFile {
	[logFileHandle closeFile];
	[logFileHandle release];
	logFileHandle = nil;
}

- (int)_flockJournalFile {
	return flock([self _logFileDescriptor], LOCK_EX | LOCK_NB);
}

- (BOOL)_acquireJournalLock {
	if ([self _flockJournalFile] == 0) return YES;
	int lockError = errno;
	struct stat info;
	BOOL regularFile = fstat([self _logFileDescriptor], &info) == 0 && S_ISREG(info.st_mode);
	if (lockError == ENOTSUP || (lockError == EINVAL && regularFile)) {
		/* unsupported filesystems run without advisory exclusion;
		 * O_EXCL still excludes a second writer, but recovery cannot distinguish
		 * a live journal until the filesystem provides a reliable lock primitive. */
		NSLog(@"Journal locking is unsupported; continuing without an advisory lock");
		return YES;
	}
	errno = lockError;
	return NO;
}

- (id)initWithRootedDirectory:(NVRootedDirectory*)root encryptionKey:(NSData*)key {
    self = [super init];
    if (self) {
		directory = [root retain];
		if (!directory) {
			[self release];
			return nil;
		}
		
		//for simplicity's sake the log file is always compressed and encrypted with the key for the current database
		//if the database has no encryption, it should have passed some constant known key to us instead
		logSessionKey = [key retain];
		
    }
    return self;
}

//called frequently--each time the app comes to the foreground?
- (BOOL)logFileStillExists {
    struct stat openFileInfo;
	int fileDescriptor = [self _logFileDescriptor];
	if (fileDescriptor < 0) return NO;
    
    //but really we shouldn't just fstat the fd because the file shouldn't be renamed or moved, either
    //on the other hand, what if another app deleted and re-created it? then any changes would be lost upon closing the fd
	if (fstat(fileDescriptor, &openFileInfo) < 0) {
		NSLog(@"logFileStillExists: fstat error: %s", strerror(errno));
		return NO;
	}
	if (![directory fileHandle:logFileHandle isStillNamed:NVJournalFilename]) return NO;
    
	return openFileInfo.st_nlink > 0;
}

- (BOOL)destroyLogFile {
	NSError *error = nil;
	if (![directory removeFileNamed:NVJournalFilename error:&error]) {
		NSLog(@"destroyLogFile: %@", error);
		return NO;
	}
	[self _closeLogFile];
	if (![directory synchronize:&error]) {
		NSLog(@"destroyLogFile directory synchronization: %@", error);
		return NO;
	}
    return YES;
}

- (void)dealloc {
	/* Closing the file handle also releases flock; some recovery transitions require that
	 * to happen synchronously when the controller's last owner releases it. */
	[self _closeLogFile];
	[directory release];
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


- (id)initWithRootedDirectory:(NVRootedDirectory*)root encryptionKey:(NSData*)key {
    self = [super initWithRootedDirectory:root encryptionKey:key];
    if (self) {
	
	//we could make parent dir writable just in case, but that might be a security hazard depending on ownership
	//chmod(path, S_IRWXU | S_IRWXG | S_IRWXO);
	
	//attempt to open/create the file exclusively with write-only and append access
	
	NSError *openError = nil;
	logFileHandle = [[directory createAppendOnlyFileExclusivelyNamed:NVJournalFilename
		permissions:S_IRUSR | S_IWUSR error:&openError] retain];
	if (!logFileHandle) {
	    //if this fails, the file probably still exists, or we don't have write permission
	    //either way, we shouldn't continue
	    
	    NSLog(@"WALStorageController: open error: %s", strerror(errno));
	    [self release];
	    return nil;
	}
	if (![self _acquireJournalLock]) {
		NSLog(@"WALStorageController: lock error: %s", strerror(errno));
		[self release];
		return nil;
	}
	if (![directory synchronize:&openError]) {
		NSLog(@"Unable to synchronize journal creation: %@", openError);
		(void)[directory removeFileNamed:NVJournalFilename error:NULL];
		[self release];
		return nil;
	}
	if (fcntl([self _logFileDescriptor], F_NOCACHE, 1) < 0) {
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
			[self destroyLogFile];
			[self release];
			return nil;
		}
		
    }
    
    return self;
}

- (BOOL)writeNoteObject:(id<SynchronizedNote>)aNoteObject {
	//this method serializes a note object, encrypts it, and writes it to the log
	NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:NO] autorelease];
	[archiver encodeObject:aNoteObject forKey:@"aNote"];
	[archiver finishEncoding];
	NSMutableData *noteData = [[[archiver encodedData] mutableCopy] autorelease];
	
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
		if ((bytesWritten = write([self _logFileDescriptor], [unwrittenData bytes], [unwrittenData length])) > 0) {
			//shift bytes backward and shrink buffer if any data could be written
			void *bytes = [unwrittenData mutableBytes];
			size_t newLength = [unwrittenData length] - bytesWritten;
			
			if (newLength > 0)
				memmove(bytes, bytes + bytesWritten, newLength);
			[unwrittenData setLength:newLength];
		} else {
			NSLog(@"Unable to empty out unwritten journal data: %s", strerror(errno));
		}
    }
    
    return ([unwrittenData length] == 0);
}

- (BOOL)_encryptAndWriteData:(NSMutableData*)data {
    WALRecordHeader record = {{0}};
	if (cannotContinueWriting) return NO;
	
	record.originalDataLength = CFSwapInt32HostToBig((UInt32)[data length]);
	
	size_t compressedDataBufferSize = [data length] + (( [data length] + 99 ) / 100 ) + 12;
	Bytef *compressedDataBuffer = (Bytef *)malloc(compressedDataBufferSize);
	if (!compressedDataBuffer) {
		NSLog(@"Unable to allocate the compressed WAL record buffer");
		return NO;
	}
	
    //adapt nsdata to compression stream
	compressionStream.next_in = (Bytef*)[data bytes];
	compressionStream.avail_in = (uInt)[data length];
	compressionStream.next_out = compressedDataBuffer;
	compressionStream.avail_out = (uInt)compressedDataBufferSize;
	compressionStream.data_type = Z_BINARY;
	
	uLong previousOut = compressionStream.total_out;
	cannotContinueWriting = YES;
	/* Perform the compression here. */
	int deflateResult = deflate(&compressionStream, Z_SYNC_FLUSH);
	/*Find the total size of the resulting compressed data. */
	uLong zlibAfterBufLen = compressionStream.total_out - previousOut;

	if (deflateResult != Z_OK) {
		NSLog(@"zlib deflation error: %s\n", compressionStream.msg);
		free(compressedDataBuffer);
		return NO;
	}
	if (zlibAfterBufLen > compressedDataBufferSize) {
		NSLog(@"zlibAfterBufLen is larger than the allocated compressed buffer!");
		free(compressedDataBuffer);
		return NO;
	}
	
	[data setLength:zlibAfterBufLen];
	memcpy([data mutableBytes], compressedDataBuffer, zlibAfterBufLen);
	free(compressedDataBuffer);
    
	//encrypt nsdata here using record salt and record key
	NSData *recordSalt = [NSData randomDataOfLength:RECORD_SALT_LEN];
    NSData *recordKey = [logSessionKey derivedKeyOfLength:(int)[logSessionKey length] salt:recordSalt iterations:1];
	
	if (![data encryptAESDataWithKey:recordKey iv:[recordSalt subdataWithRange:NSMakeRange(0, 16)]]) {
		NSLog(@"Couldn't encrypt WAL record data!");
		return NO;
	}
	
	//write length, checksum of data, record salt, then data itself
    //assert(sizeof(record) == sizeof(record.recordBuffer));
    
    record.dataLength = CFSwapInt32HostToBig((UInt32)[data length]);
    record.checksum = CFSwapInt32HostToBig((UInt32)[data CRC32]);
	memcpy(record.saltBuffer, [recordSalt bytes], RECORD_SALT_LEN);
    
    //pack all the data to avoid multiple writes
    size_t dataChunkSize = sizeof(record) + (size_t)[data length];
    char *dataChunk = (char*)malloc(dataChunkSize);
	if (!dataChunk) {
		NSLog(@"Unable to allocate the complete WAL record buffer");
		return NO;
	}
    
    memcpy(dataChunk, record.recordBuffer, sizeof(record.recordBuffer));
    memcpy(dataChunk + sizeof(record.recordBuffer), [data bytes], (size_t)[data length]);
    
    ssize_t bytesWritten = 0;
    
    //attempt to write any buffered data first
    if ([self _attemptToWriteUnwrittenData]) {
		//always append data in the right order; if there is old buffered data, then the new data is buffered until that is empty
		//otherwise the new data is appended immediately
		
		bytesWritten = write([self _logFileDescriptor], dataChunk, dataChunkSize);
    }
    
    if (bytesWritten < 0) {
		NSLog(@"Unable to write new journal data: %s", strerror(errno));
		bytesWritten = 0;
    }
	
    if ((size_t)bytesWritten < dataChunkSize) {
		//buffer any remaining data that we were not able to write (in case the disk was full, for example)
		[unwrittenData appendBytes:dataChunk + bytesWritten length:(dataChunkSize - bytesWritten)];
    }
    
    free(dataChunk);
    
	/* Once appended here, the WAL owns every remaining byte in unwrittenData.
	 * The controller may therefore retire the note-level journal obligation;
	 * -synchronize remains responsible for draining and barrier-syncing this byte outbox. */
	cannotContinueWriting = NO;
	return YES;
}

- (BOOL)synchronize {
    
    BOOL flushedUnwritten = [self _attemptToWriteUnwrittenData];
    
	if (NVBarrierSyncFileDescriptor([self _logFileDescriptor]) < 0) {
		NSLog(@"synchronize WAL: barrier sync error: %s", strerror(errno));
		return NO;
    }
    
    return flushedUnwritten;
}

- (void)dealloc {
	if (compressionStream.state) deflateEnd(&compressionStream);
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
//The startup coordinator owns database persistence and WAL replacement. This
//class only holds the existing journal lock and scans recoverable records.

- (id)initWithRootedDirectory:(NVRootedDirectory*)root encryptionKey:(NSData*)key
	error:(int*)errorNumber journalInUse:(BOOL*)journalInUse {
	if (errorNumber) *errorNumber = 0;
	if (journalInUse) *journalInUse = NO;
    self = [super initWithRootedDirectory:root encryptionKey:key];
    if (self) {
	fileLength = totalBytesRead = 0;
	
	//attempt to open file read-only
	NSError *openErrorObject = nil;
	logFileHandle = [[directory openExistingRegularFileNonblockingNamed:NVJournalFilename
		error:&openErrorObject] retain];
	if (!logFileHandle) {
		int openError = (int)[openErrorObject code];
	    NSLog(@"WALRecoveryController: open error: %s", strerror(errno));
		if (errorNumber) *errorNumber = openError;
	    [self release];
	    return nil;
	}
	if (![self _acquireJournalLock]) {
		int lockError = errno;
		NSLog(@"WALRecoveryController: journal is in use: %s", strerror(lockError));
		if (errorNumber) *errorNumber = lockError;
		if (journalInUse)
			*journalInUse = lockError == EWOULDBLOCK || lockError == EAGAIN;
		[self release];
		return nil;
	}
	struct stat sb;
	if (fstat([self _logFileDescriptor], &sb) < 0) {
		int statError = errno;
	    NSLog(@"WALRecoveryController: fstat error: %s", strerror(errno));
		if (errorNumber) *errorNumber = statError;
	    [self release];
	    return nil;
	}
	
	if (!S_ISREG(sb.st_mode)) {
	    NSLog(@"WALRecoveryController: log file is not a regular file");
		if (errorNumber) *errorNumber = S_ISDIR(sb.st_mode) ? EISDIR : EINVAL;
	    [self release];
	    return nil;
	}
	(void)fchmod([self _logFileDescriptor], S_IRUSR);
	
	fileLength = sb.st_size;
	
	//initialize decompression context
	compressionStream.total_in = 0;
	compressionStream.total_out = 0;
	compressionStream.zalloc = Z_NULL;
	compressionStream.zfree = Z_NULL;
	compressionStream.opaque = Z_NULL;
	
	if (inflateInit2(&compressionStream, MAX_WBITS) != Z_OK) {
		NSLog(@"inflateInit2 error: %s", compressionStream.msg);
		if (errorNumber) *errorNumber = EIO;
		[self release];
		return nil;
	}
	
    }
    return self;
}

//log enumerating method
- (WALRecordRecoveryResult)recoverNextObject:(id<SynchronizedNote>*)recoveredObject {
	WALRecordHeader record = {{0}};
	NSMutableData *serializedData = nil;
	NSData *uncompressedData = nil;
	Bytef *uncompressedBytes = NULL;
	WALRecordRecoveryResult result = WALRecoveryStopped;
	if (recoveredObject) *recoveredObject = nil;

	/* Decide benign damaged-tail cases from the length captured while the file is
	 * locked.  An unexpected short read inside that boundary is a hard stop. */
	off_t bytesRemaining = fileLength - totalBytesRead;
	if (bytesRemaining <= 0) return WALRecoveryEnded;
	if (bytesRemaining < (off_t)sizeof(record)) {
		NSLog(@"recoverNextObject found a truncated log record header");
		return WALRecoveryEnded;
	}
	int readError = 0;
	ssize_t readBytes = NVReadWALBytes([self _logFileDescriptor], &record, sizeof(record), &readError);
	totalBytesRead += readBytes;
	if (readError || readBytes != (ssize_t)sizeof(record)) {
		NSLog(@"recoverNextObject can't read the complete log record header%@",
			readError ? [NSString stringWithFormat:@": %s", strerror(readError)] : @"");
		return WALRecoveryStopped;
	}

	record.originalDataLength = CFSwapInt32BigToHost(record.originalDataLength);
	record.dataLength = CFSwapInt32BigToHost(record.dataLength);
	record.checksum = CFSwapInt32BigToHost(record.checksum);
	if (!record.originalDataLength || !record.dataLength) {
		NSLog(@"recoverNextObject found an invalid zero-length record");
		return WALRecoveryStopped;
	}
	if (totalBytesRead > fileLength || record.dataLength > (uint64_t)(fileLength - totalBytesRead)) {
		NSLog(@"recoverNextObject found a truncated final record");
		return WALRecoveryEnded;
	}

	char *encryptedBytes = (char*)malloc(record.dataLength);
	if (!encryptedBytes) {
		NSLog(@"Unable to allocate the encrypted WAL record buffer");
		return WALRecoveryStopped;
	}
	readError = 0;
	readBytes = NVReadWALBytes([self _logFileDescriptor], encryptedBytes, record.dataLength, &readError);
	totalBytesRead += readBytes;
	if (readBytes != (ssize_t)record.dataLength) {
		NSLog(@"recoverNextObject can't read all serialized bytes%@", readError ?
			[NSString stringWithFormat:@": %s", strerror(readError)] : @"");
		free(encryptedBytes);
		return WALRecoveryStopped;
	}

	serializedData = [[NSMutableData alloc] initWithBytesNoCopy:encryptedBytes
		length:record.dataLength freeWhenDone:YES];
	if (!serializedData) {
		free(encryptedBytes);
		return WALRecoveryStopped;
	}
	if ([serializedData CRC32] != record.checksum) {
		NSLog(@"recoverNextObject: checksum of read data does not match that of record header");
		goto cleanup;
	}

	NSData *recordSalt = [NSData dataWithBytesNoCopy:record.saltBuffer
		length:RECORD_SALT_LEN freeWhenDone:NO];
	NSData *recordKey = [logSessionKey derivedKeyOfLength:(int)[logSessionKey length]
		salt:recordSalt iterations:1];
	if (![serializedData decryptAESDataWithKey:recordKey
		iv:[recordSalt subdataWithRange:NSMakeRange(0, 16)]]) {
		NSLog(@"Record decryption failed!");
		goto cleanup;
	}

	uncompressedBytes = (Bytef*)malloc(record.originalDataLength);
	if (!uncompressedBytes) {
		NSLog(@"Unable to allocate the WAL recovery buffer");
		goto cleanup;
	}
	compressionStream.avail_in = (uInt)[serializedData length];
	compressionStream.next_in = (Bytef*)[serializedData bytes];
	compressionStream.avail_out = (uInt)record.originalDataLength;
	compressionStream.next_out = uncompressedBytes;
	compressionStream.data_type = Z_BINARY;

	/* The writer uses one continuous zlib stream.  Successfully consuming this
	 * record's complete compressed segment is what makes the next record usable. */
	int inflateResult = inflate(&compressionStream, Z_SYNC_FLUSH);
	if (inflateResult != Z_OK && inflateResult != Z_BUF_ERROR) {
		NSLog(@"recoverNextObject: zlib inflate error %d: %s", inflateResult,
			compressionStream.msg ?: "unknown error");
		goto cleanup;
	}
	BOOL declaredLengthTooLarge = compressionStream.avail_out != 0;
	if (compressionStream.avail_in || !declaredLengthTooLarge) {
		/* A full output buffer can leave decoded bytes pending even after zlib has
		 * consumed all input.  Probe and drain until a no-output call proves that
		 * this record's segment boundary has been reached. */
		Bytef discard[4096];
		BOOL producedExtraOutput = NO;
		while (1) {
			uInt inputBefore = compressionStream.avail_in;
			compressionStream.next_out = discard;
			compressionStream.avail_out = sizeof(discard);
			inflateResult = inflate(&compressionStream, Z_SYNC_FLUSH);
			uInt outputProduced = sizeof(discard) - compressionStream.avail_out;
			if ((inflateResult != Z_OK && inflateResult != Z_BUF_ERROR) ||
				(compressionStream.avail_in == inputBefore && !outputProduced &&
				 compressionStream.avail_in)) {
				NSLog(@"recoverNextObject could not reach the compressed record boundary");
				goto cleanup;
			}
			if (outputProduced) producedExtraOutput = YES;
			if (!compressionStream.avail_in && !outputProduced) break;
		}
		if (producedExtraOutput) {
			NSLog(@"recoverNextObject found more decompressed data than declared");
			result = WALRecordSkipped;
			goto cleanup;
		}
	}
	if (declaredLengthTooLarge) {
		NSLog(@"recoverNextObject found less decompressed data than declared");
		result = WALRecordSkipped;
		goto cleanup;
	}

	[serializedData release];
	serializedData = nil;
	uncompressedData = [[NSData alloc] initWithBytesNoCopy:uncompressedBytes
		length:record.originalDataLength freeWhenDone:YES];
	if (!uncompressedData) goto cleanup;
	uncompressedBytes = NULL;
	/* Unarchiving happens only after zlib consumed the complete segment, so an
	 * archive exception or wrong object type can skip this record and continue. */
	id object = nil;
	@try {
		NSError *unarchiveError = nil;
		NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc]
			initForReadingFromData:uncompressedData error:&unarchiveError] autorelease];
		[unarchiver setRequiresSecureCoding:NO];
		object = [unarchiver decodeTopLevelObjectForKey:@"aNote" error:&unarchiveError];
		[unarchiver finishDecoding];
		if (!object)
			NSLog(@"recoverNextObject could not unarchive object: %@", unarchiveError);
	} @catch (NSException *exception) {
		object = nil;
		NSLog(@"recoverNextObject got an exception while unarchiving object: %@",
			[exception reason]);
	}
	if (!object || ![object conformsToProtocol:@protocol(SynchronizedNote)]) {
		if (object) NSLog(@"Recovered object of class %@ does not conform to SynchronizedNote",
			[object className]);
		result = WALRecordSkipped;
		goto cleanup;
	}
	if (recoveredObject) *recoveredObject = object;
	result = WALRecordRecovered;

cleanup:
	free(uncompressedBytes);
	[uncompressedData release];
	[serializedData release];
	return result;
}

- (void)dealloc {
	if (compressionStream.state) inflateEnd(&compressionStream);
	[super dealloc];
}

static CFStringRef SynchronizedNoteKeyDescription(const void *value) {

	return value ? (CFStringRef)[NSString uuidStringWithBytes:*(CFUUIDBytes*)value] : NULL;
}
static CFHashCode SynchronizedNoteHash(const void * o) {
	
	return CFHashBytes((const uint8_t *)o, sizeof(CFUUIDBytes));
}
static Boolean SynchronizedNoteIsEqual(const void *o, const void *p) {
	
	return (!memcmp((CFUUIDBytes*)o, (CFUUIDBytes*)p, sizeof(CFUUIDBytes)));
}

//we keep a table of the newest recovered notes, as any changed notes will almost certainly be written multiple times
//throw away objects with LSNs lower than the current highest one for each UUID
//and when recovery cannot progress any further, only the newest objects will be exchanged

- (NSDictionary*)recoveredNotesWithIncompleteRecovery:(BOOL*)incomplete {
	id <SynchronizedNote> obj = nil;
	CFUUIDBytes *objUUIDBytes = NULL;
    
    CFDictionaryKeyCallBacks keyCallbacks = kCFTypeDictionaryKeyCallBacks;
    keyCallbacks.equal = SynchronizedNoteIsEqual;
    keyCallbacks.hash = SynchronizedNoteHash;
	keyCallbacks.copyDescription = SynchronizedNoteKeyDescription;
	keyCallbacks.retain = NULL;
	keyCallbacks.release = NULL;
    
    CFMutableDictionaryRef recoveredNotes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &keyCallbacks, &kCFTypeDictionaryValueCallBacks);
    
	/* A skipped record marks the result incomplete but preserves stream progress;
	 * a stopped record marks it incomplete and preserves only the valid prefix. */
	BOOL recoveryIncomplete = NO;
	while (1) {
		WALRecordRecoveryResult result = [self recoverNextObject:&obj];
		if (result == WALRecoveryEnded) break;
		if (result == WALRecoveryStopped) {
			recoveryIncomplete = YES;
			break;
		}
		if (result == WALRecordSkipped) {
			recoveryIncomplete = YES;
			continue;
		}

		/* A note may occur many times in one WAL.  UUID+LSN coalescing makes replay
		 * idempotent and also preserves the newest deletion object. */
		objUUIDBytes = [obj uniqueNoteIDBytes];
		id <SynchronizedNote> foundNote = nil;
		if (CFDictionaryGetValueIfPresent(recoveredNotes, (const void *)objUUIDBytes,
			(const void **)&foundNote) && foundNote && ![foundNote youngerThanLogObject:obj])
			continue;
		CFDictionarySetValue(recoveredNotes, (const void *)objUUIDBytes, (const void *)obj);
	}
	if (incomplete) *incomplete = recoveryIncomplete;
	return [(NSDictionary*)recoveredNotes autorelease];
}

@end
