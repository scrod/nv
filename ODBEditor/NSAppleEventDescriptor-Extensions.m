#import "NSAppleEventDescriptor-Extensions.h"

@implementation NSAppleEventDescriptor(Extensions)

+ (NSAppleEventDescriptor *)descriptorWithFilePath:(NSString *)fileName {
	NSURL   *url = [NSURL fileURLWithPath: fileName];
	return [self descriptorWithFileURL: url];
}


@end
