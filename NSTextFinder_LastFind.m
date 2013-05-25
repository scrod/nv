/*
 *  NSTextFinder_LastFind.h
 *  Notation
 *
 *  Created by Zachary Schneirov
 *
 */
#include <AppKit/NSTextFinder.h>
#import "LinkingEditor.h"

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

