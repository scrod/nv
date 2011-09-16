/*
 *  NSTextFinder_LastFind.h
 *  Notation
 *
 *  Created by Zachary Schneirov
 *
 */
#import "NSTextFinder.h"

//#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_7
@implementation NSTextFinder (LastFind)

- (int)nv_lastFindWasSuccessful {
	@try {
    NSNumber *success = [self valueForKey:@"lastFindWasSuccessful"];
    if (success)
        return ([success boolValue] ? LAST_FIND_YES : LAST_FIND_NO);
    } @catch (NSException *e) {}
    
	NSLog(@"lastFindWasSuccessful ivar not found!");
	return LAST_FIND_UNKNOWN;
}

@end
//#endif
