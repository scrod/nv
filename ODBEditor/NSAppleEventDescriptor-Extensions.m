#import "NSAppleEventDescriptor-Extensions.h"

@implementation NSAppleEventDescriptor(Extensions)

+ (NSAppleEventDescriptor *)descriptorWithFilePath:(NSString *)fileName {
	NSURL   *url = [NSURL fileURLWithPath: fileName];
	return [self descriptorWithFileURL: url];
}


// Provide a consistent implementation for creating file URL AppleEvent descriptors.
// This improves reliability when sending ODB events to external editors.
+ (NSAppleEventDescriptor *)descriptorWithFileURL:(NSURL *)fileURL {
	NSString *string = [fileURL absoluteString];
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
	return [self descriptorWithDescriptorType:typeFileURL data:data];
}


@end
