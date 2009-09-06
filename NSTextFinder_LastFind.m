/*
 *  NSTextFinder_LastFind.h
 *  Notation
 *
 *  Created by Zachary Schneirov
 *
 */
#include <objc/objc-runtime.h>
#import "NSTextFinder.h"

@implementation NSTextFinder (LastFind)

- (int)lastFindWasSuccessful {
	int i;
	Ivar ivar;
	
	//this might not work so well with Obj-C 2
	for (i = 0; i < isa->ivars->ivar_count; i++ ) {
		ivar = &isa->ivars->ivar_list[i];
		if (strcmp( ivar->ivar_name, "lastFindWasSuccessful") == 0) {
			
			BOOL *lastFind = ((BOOL*) self + ivar->ivar_offset);
			
			return *lastFind ? LAST_FIND_YES : LAST_FIND_NO;
		}
	}
	
	NSLog(@"No lastFindWasSuccessful ivars found!");
	return LAST_FIND_UNKNOWN;
}

@end

