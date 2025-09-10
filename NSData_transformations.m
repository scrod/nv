
/*
 * Compresses/decompresses data using zlib (see RFC 1950 and /usr/include/zlib.h)
 *
 * Be sure to add /usr/lib/libz.dylib to the linked frameworks, or add "-lz" to
 * 'Other Linker Flags' in the 'Linker Settings' section of the target's
 * 'Build Settings'
 *
 */

/* NSData_transformations.m */

#import "NSData_transformations.h"
#import <CommonCrypto/CommonKeyDerivation.h>
#include "broken_md5.h"

#include <unistd.h>
#include <stdint.h>
#include <zlib.h>
#import <CommonCrypto/CommonCrypto.h>
#import <WebKit/WebKit.h>
#import <Security/Security.h>

NSData *ExecuteTransformWithInput(NSData *input, SecTransformRef transform) {
	NSData *output = nil;
	assert(transform);
	assert(input);
	
	if (SecTransformSetAttribute(transform, kSecTransformInputAttributeName, input, NULL))
		output = (NSData *)SecTransformExecute(transform, NULL);
	
	return [output autorelease];
}


@implementation NSData (NVUtilities)

/*
 * Compress the data, default level of compression
 */
- (NSMutableData *)compressedData {
	return [self compressedDataAtLevel:Z_DEFAULT_COMPRESSION];
}


/*
 * Compress the data at the given compression level; stores the original data
 * size at the end of the compressed data
 */
- (NSMutableData *)compressedDataAtLevel:(int)level {
	
	NSMutableData *newData;
	unsigned long bufferLength;
	int zlibError;
	
	/*
	 * zlib says to make sure the destination has 0.1% more + 12 bytes; last
	 * additional bytes to store the original size (needed for uncompress)
	 */
	bufferLength = ceil( (float) [self length] * 1.001 ) + 12 + sizeof( unsigned );
	newData = [NSMutableData dataWithLength:bufferLength];
	if( newData != nil ) {
		zlibError = compress2([newData mutableBytes], &bufferLength,
							   [self bytes], [self length], level);
		if (zlibError == Z_OK) {
			// Add original size to the end of the buffer, written big-endian
			// Use memcpy to avoid undefined behavior from unaligned stores
			uint32_t origLenBE = NSSwapHostIntToBig((uint32_t)[self length]);
			memcpy(((uint8_t *)[newData mutableBytes]) + bufferLength, &origLenBE, sizeof(origLenBE));
			[newData setLength:bufferLength + sizeof(origLenBE)];
		} else {
			NSLog(@"error compressing: %s", zError(zlibError));
			newData = nil;
		}
	} else
		NSLog(@"error compressing: couldn't allocate memory");
	
	return newData;
}


/*
 * Decompress data
 */
- (NSMutableData *) uncompressedData {
	
	NSMutableData *newData;
	uint32_t originalSize;
	unsigned long outSize;
	int zlibError;
	
	newData = nil;
	if ( [self isCompressedFormat] ) {
		// Read original size from the last 4 bytes (big-endian), using memcpy to avoid unaligned loads
		uint32_t beSize = 0;
		memcpy(&beSize, ((const uint8_t *)[self bytes]) + [self length] - sizeof(beSize), sizeof(beSize));
		originalSize = NSSwapBigIntToHost(beSize);
		
		//catch the NSInvalidArgumentException that's thrown if originalSize is too large
		NS_DURING
			newData = [ NSMutableData dataWithLength:originalSize ];
		NS_HANDLER
			if ([[localException name] isEqualToString:NSInvalidArgumentException] ) {
				NSLog(@"error decompressing--bad size: %@", [localException reason]);
				NS_VALUERETURN( nil, NSMutableData * );
			} else
				[localException raise];   // This should NEVER happen...
		NS_ENDHANDLER
		
		if( newData != nil ) {
			outSize = originalSize;
			zlibError = uncompress([newData mutableBytes], &outSize, [self bytes], [self length] - sizeof(unsigned));
			if( zlibError != Z_OK ) {
				NSLog(@"decompression failed: %s", zError(zlibError));
				newData = nil;
			} else if (originalSize != outSize)
				NSLog(@"error decompressing: extracted size %lu does not match original of %u", outSize, originalSize);
		} else
			NSLog(@"error allocating memory while decompressing");
	} else
		NSLog(@"error decompressing: data does not seem to be compressed with zlib");
	
	return newData;
}


/*
 * Quick check of the data to avoid obviously-not-compressed data (see RFC)
 */
- (BOOL)isCompressedFormat {
	const unsigned char *bytes;
	
	bytes = [self bytes];
	/*
	 * The checks are:
	 *    ( *bytes & 0x0F ) == 8           : method is deflate (this is called CM compression method, in the RFC)
	 *    ( *bytes & 0x80 ) == 0           : info must be at most seven, this makes sure the MSB is not set, otherwise it
	 *                                       is at least 8 (this is called CINFO, compression info, in the RFC)
	 *    *( (short *) bytes ) ) % 31 == 0 : the two first bytes as a whole (big endian format) must be a multiple of 31
	 *                                       (this is discussed in the FCHECK in FLG, flags, section)
	 */
	if( ( *bytes & 0x0F ) == 8 && ( *bytes & 0x80 ) == 0 ) {
		uint16_t hdr = 0;
		memcpy(&hdr, bytes, sizeof(hdr)); // avoid potential unaligned short load
		if (NSSwapBigShortToHost(hdr) % 31 == 0)
			return YES;
	}
	
	return NO;
}

+ (NSMutableData *)randomDataOfLength:(int)len {
	if (len <= 0) return [NSMutableData data];

	NSMutableData *randomData = [NSMutableData dataWithLength:(NSUInteger)len];
	OSStatus status = SecRandomCopyBytes(kSecRandomDefault, (size_t)len, [randomData mutableBytes]);
	if (status != errSecSuccess) {
		NSLog(@"SecRandomCopyBytes failed (status=%d)", (int)status);
		return nil;
	}
	return randomData;
}

- (NSMutableData*)derivedKeyOfLength:(int)len salt:(NSData*)salt iterations:(int)count {
    NSMutableData *derivedKey = [NSMutableData dataWithLength:len];

    CCStatus status = CCKeyDerivationPBKDF(kCCPBKDF2,
                                           (const char *)[self bytes], (size_t)[self length],
                                           (const uint8_t *)[salt bytes], (size_t)[salt length],
                                           kCCPRFHmacAlgSHA1,
                                           (uint32_t)count,
                                           (uint8_t *)[derivedKey mutableBytes], (size_t)len);

    if (status != kCCSuccess) {
        NSLog(@"CCKeyDerivationPBKDF failed (status=%d)", (int)status);
        return nil;
    }

    return derivedKey;
}

- (unsigned long)CRC32 {
	uLong crc = crc32(0L, Z_NULL, 0);
    return crc32(crc, [self bytes], (uInt)[self length]);
}

- (NSData*)SHA1Digest {
	unsigned char digest[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1(self.bytes, (CC_LONG)self.length, digest);
	return [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
}

- (NSData*)BrokenMD5Digest {
	BrokenMD5_CTX context;
	NSMutableData *digest = [NSMutableData dataWithLength:16];
    
    BrokenMD5Init(&context);
    BrokenMD5Update(&context, [self bytes], (unsigned int)[self length]);
    BrokenMD5Final([digest mutableBytes], &context);
	
	return digest;
}

- (NSData*)MD5Digest {
	CC_MD5_CTX ctx;
	CC_MD5_Init(&ctx);
	CC_MD5_Update(&ctx, self.bytes, (CC_LONG)self.length);

	unsigned char md[CC_MD5_DIGEST_LENGTH];
	CC_MD5_Final(md, &ctx);

	return [NSData dataWithBytes:md length:CC_MD5_DIGEST_LENGTH];
}


- (NSString*)pathURLFromWebArchive {

	WebResource *resource = [[[[WebArchive alloc] initWithData:self] autorelease] mainResource];
	NSURL *url = [resource URL];
	
	//it's not any kind of URL we want to keep
	//this is probably text from another app's internal WebKit view
	if ([[url scheme] isEqualToString:@"applewebdata"] || [[url scheme] isEqualToString:@"x-msg"])
		return nil;
	
	return [url absoluteString];
}

- (BOOL)fsRefAsAlias:(FSRef*)fsRef {
    AliasHandle aliasHandle;
    Boolean changedThrownAway;
    
    if (self && PtrToHand([self bytes], (Handle*)&aliasHandle, [self length]) == noErr) {
		
		if (FSResolveAliasWithMountFlags(NULL, aliasHandle, fsRef, &changedThrownAway, kResolveAliasFileNoUI) == noErr)
			return YES;
    }
	
    return NO;
}

+ (NSData*)uncachedDataFromFile:(NSString*)filename {
			
	return [NSData dataWithContentsOfFile:filename options:NSUncachedRead error:NULL];
}

+ (NSData*)aliasDataForFSRef:(FSRef*)fsRef {
    
    FSRef userHomeFoundRef, *relativeRef = &userHomeFoundRef;
    
    OSErr err = FSFindFolder(kUserDomain, kCurrentUserFolderType, kCreateFolder, &userHomeFoundRef);
    if (err != noErr) {
		relativeRef = NULL;
		NSLog(@"FSFindFolder error: %d", err);
    }
    
    AliasHandle aliasHandle;
    NSData *theData = nil;
    
    //fill handle from fsref, storing path relative to user directory
    if (FSNewAlias(relativeRef, fsRef, &aliasHandle) == noErr && aliasHandle != NULL) {
		HLock((Handle)aliasHandle);
		theData = [NSData dataWithBytes:*aliasHandle length:GetHandleSize((Handle) aliasHandle)];
		HUnlock((Handle)aliasHandle);
    }
    
    return theData;
}

//yes, to do the same encoding detection we could use something like initWithContentsOfFile: or 
//initWithContentsOfFile:(NSString *)path usedEncoding:(NSStringEncoding *)enc error:(NSError **)error
//but those 1) require file paths and 2) the non-deprecated version is available only on 10.4

- (NSMutableString*)newStringUsingBOMReturningEncoding:(NSStringEncoding*)encoding {
	NSUInteger len = [self length];
	NSMutableString *string = nil;
	
	if (len % 2 != 0 || !len) {
		return nil;
	}
	const unichar byteOrderMark = 0xFEFF;
	const unichar byteOrderMarkSwapped = 0xFFFE;
	
	BOOL foundBOM = NO;
	BOOL swapped = NO;
	unsigned char *b = (unsigned char*)[self bytes];
	unichar firstWord = 0;
	memcpy(&firstWord, b, sizeof(firstWord)); // avoid potential unaligned unichar load
	
	if (firstWord == byteOrderMark) {
		b += sizeof(unichar);
		len -= sizeof(unichar);
		foundBOM = YES;
	} else if (firstWord == byteOrderMarkSwapped) {
		b += sizeof(unichar);
		len -= sizeof(unichar);
		swapped = YES;
		foundBOM = YES;
	} else if (len > 2 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
		len -= 3;
		b += 3;
		
		//false because we just fixed the BOM right up there
		//string = (NSString*)CFStringCreateWithBytes(kCFAllocatorDefault, b, len, kCFStringEncodingUTF8, false);
		string = [[NSMutableString alloc] initWithBytes:b length:len encoding:NSUTF8StringEncoding];
		if (string)
			*encoding = NSUTF8StringEncoding;
		
		return string;
	}
	
	if (foundBOM) {
		unsigned char *u = (unsigned char*)malloc((size_t)len);
		if (swapped) {
			NSUInteger i;
			
			for (i = 0; i < len; i += 2) {
				u[i] = b[i + 1];
				u[i + 1] = b[i];
			}
		} else {
			memcpy(u, b, len);
		}
		
		
		string = (NSMutableString*)CFStringCreateMutableWithExternalCharactersNoCopy(NULL, (UniChar *)u, (CFIndex)len/2, (CFIndex)len/2, kCFAllocatorDefault);
		if (string)
			*encoding = NSUnicodeStringEncoding;
		return string;
	}
	
	return nil;
}

- (NSString *)encodeBase64WithoutNewlines {
	SecTransformRef const transform = SecEncodeTransformCreate(kSecBase64Encoding, NULL);
	
	NSString *const str = [[[NSString alloc] initWithData:ExecuteTransformWithInput(self, transform) encoding:NSASCIIStringEncoding] autorelease];
	
	CFRelease(transform);
	return str;
}


@end

@implementation NSMutableData (NVCryptoRelated)


- (void)reverseBytes {
	NSInteger head, tail;
	unsigned char temp, *str = [self mutableBytes];
	if (!str) return;
	tail = (NSInteger)[self length] - 1;
	
	for (head = 0; head < tail; ++head, --tail) {
		temp = str[tail];
		str[tail] = str[head];
		str[head] = temp;
	}
}

//extends nsmutabledata if necessary
- (void)alignForBlockSize:(int)alignedBlockSize {
		NSUInteger dataBlockSize = [self length];
		NSUInteger paddedDataBlockSize = 0;
		
		if (dataBlockSize <= (NSUInteger)alignedBlockSize)
			paddedDataBlockSize = alignedBlockSize;
		else
			paddedDataBlockSize = (NSUInteger)alignedBlockSize * ((dataBlockSize + ((NSUInteger)alignedBlockSize-1)) / (NSUInteger)alignedBlockSize);

	//if malloc was used on conventional architectures, nsdata should be smart enough not to have to allocate a new block
	NSInteger difference = (NSInteger)paddedDataBlockSize - (NSInteger)dataBlockSize;
	if (difference > 0)
		[self increaseLengthBy:(NSUInteger)difference];	
}

- (BOOL)encryptAESDataWithKey:(NSData*)key iv:(NSData*)iv {
	// AES-256-CBC with PKCS7 padding to match OpenSSL EVP defaults
	const size_t expectedKeyLen = kCCKeySizeAES256; // 32
	const size_t expectedIVLen  = kCCBlockSizeAES128; // 16

	if ([key length] != expectedKeyLen) {
		NSLog(@"encryption key length was wrong size: %lu", (unsigned long)[key length]);
		return NO;
	}
	if ([iv length] != expectedIVLen) {
		NSLog(@"initialization vector length was wrong size: %lu", (unsigned long)[iv length]);
		return NO;
	}

	size_t dataInLength = [self length];
	size_t outBufferSize = dataInLength + kCCBlockSizeAES128; // allow for padding
	NSMutableData *outData = [NSMutableData dataWithLength:outBufferSize];

	size_t outMoved = 0;
	CCCryptorStatus status = CCCrypt(kCCEncrypt,
									 kCCAlgorithmAES,
									 kCCOptionPKCS7Padding, // CBC mode is default when IV provided
									 [key bytes], expectedKeyLen,
									 [iv bytes],
									 [self bytes], dataInLength,
									 [outData mutableBytes], outBufferSize,
									 &outMoved);

	if (status != kCCSuccess) {
		NSLog(@"Couldn't encrypt data (status=%d)", (int)status);
		return NO;
	}

	[outData setLength:outMoved];
	[self setData:outData];
	return YES;
}

- (BOOL)decryptAESDataWithKey:(NSData*)key iv:(NSData*)iv {
	// AES-256-CBC with PKCS7 padding to match OpenSSL EVP defaults
	const size_t expectedKeyLen = kCCKeySizeAES256; // 32
	const size_t expectedIVLen  = kCCBlockSizeAES128; // 16

	if ([key length] != expectedKeyLen) {
		NSLog(@"decryption key length was wrong size: %lu", (unsigned long)[key length]);
		return NO;
	}
	if ([iv length] != expectedIVLen) {
		NSLog(@"initialization vector length was wrong size: %lu", (unsigned long)[iv length]);
		return NO;
	}

	size_t dataInLength = [self length];
	// For decryption, output won't be bigger than input
	NSMutableData *outData = [NSMutableData dataWithLength:dataInLength];

	size_t outMoved = 0;
	CCCryptorStatus status = CCCrypt(kCCDecrypt,
									 kCCAlgorithmAES,
									 kCCOptionPKCS7Padding, // must match encryption
									 [key bytes], expectedKeyLen,
									 [iv bytes],
									 [self bytes], dataInLength,
									 [outData mutableBytes], [outData length],
									 &outMoved);

	if (status != kCCSuccess) {
		NSLog(@"Couldn't decrypt data (status=%d)", (int)status);
		return NO;
	}

	[outData setLength:outMoved];
	[self setData:outData];
	return YES;
}


@end
