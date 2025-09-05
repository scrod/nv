#import <Foundation/Foundation.h>

@interface NSAppleEventDescriptor(Extensions)

+ (NSAppleEventDescriptor *)descriptorWithFilePath:(NSString *)fileName;
#if !defined(MAC_OS_X_VERSION_10_6) || (MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_6)
+ (NSAppleEventDescriptor *)descriptorWithFileURL:(NSURL *)fileURL;
#endif

@end
