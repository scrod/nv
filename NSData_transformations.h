
/*
 * You need to have the OpenSSL header files (as well as the location of their
 * include directory given to Project Builder) for this to compile.  For it
 * to link, add /usr/lib/libcrypto.dylib and /usr/lib/libssl.dylib to the linked
 * frameworks.
 */
/* NSData_crypto.h */

#import <Foundation/Foundation.h>
#include <openssl/evp.h>

@interface NSData (NVUtilities)

- (NSMutableData *) compressedData;
- (NSMutableData *) compressedDataAtLevel:(int)level;
- (NSMutableData *) uncompressedData;
- (BOOL) isCompressedFormat;

+ (NSMutableData *)randomDataOfLength:(int)len;
- (NSMutableData*)derivedKeyOfLength:(int)len salt:(NSData*)salt iterations:(int)count;
- (unsigned long)CRC32;
- (NSData*)SHA1Digest;
- (NSData*)MD5Digest;
- (NSData*)BrokenMD5Digest;

- (NSString*)pathURLFromWebArchive;

- (BOOL)fsRefAsAlias:(FSRef*)fsRef;
+ (NSData*)aliasDataForFSRef:(FSRef*)fsRef;
- (NSMutableString*)newStringUsingBOMReturningEncoding:(NSStringEncoding*)encoding;
+ (NSData*)uncachedDataFromFile:(NSString*)filename;

- (NSString *)encodeBase64;
- (NSString *)encodeBase64WithNewlines:(BOOL)encodeWithNewlines;

@end

@interface NSMutableData (NVCryptoRelated)
- (void)reverseBytes;
- (void)alignForBlockSize:(int)alignedBlockSize;

- (BOOL)encryptAESDataWithKey:(NSData*)key iv:(NSData*)iv;
- (BOOL)decryptAESDataWithKey:(NSData*)key iv:(NSData*)iv;

- (BOOL)encryptDataWithCipher:(const EVP_CIPHER*)cipher key:(NSData*)key iv:(NSData*)iv;
- (BOOL)decryptDataWithCipher:(const EVP_CIPHER*)cipher key:(NSData*)key iv:(NSData*)iv;

@end
