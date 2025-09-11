#import <Foundation/Foundation.h>

@interface NSAppleEventDescriptor(Extensions)

+ (NSAppleEventDescriptor *)descriptorWithFilePath:(NSString *)fileName;
+ (NSAppleEventDescriptor *)descriptorWithFileURL:(NSURL *)fileURL;

@end
