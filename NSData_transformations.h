#import <Foundation/Foundation.h>

NSData *ExecuteTransformWithInput(NSData *input, SecTransformRef transform);

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

- (NSString *)encodeBase64WithoutNewlines;

@end

@interface NSMutableData (NVCryptoRelated)
- (void)reverseBytes;
- (void)alignForBlockSize:(int)alignedBlockSize;

- (BOOL)encryptAESDataWithKey:(NSData*)key iv:(NSData*)iv;
- (BOOL)decryptAESDataWithKey:(NSData*)key iv:(NSData*)iv;

@end
