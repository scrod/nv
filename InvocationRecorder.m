//
//  InvocationRecorder.m
//  Notation
//

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */

#import "InvocationRecorder.h"


@implementation InvocationRecorder

+ (id)invocationRecorder {
	return [[[self alloc] init] autorelease];
}

- (void)dealloc {
	[target release];
	[invocation release];
	[super dealloc];
}

- (id)target {
	return target;
}
- (NSInvocation *)invocation {
	return invocation; 
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSEL {
	//check the superclass first
	
	NSMethodSignature *theMethodSignature = [super methodSignatureForSelector:aSEL];
	return theMethodSignature ? theMethodSignature : [target methodSignatureForSelector:aSEL];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
	if (invocation != anInvocation) {
		[invocation autorelease];
		invocation = [anInvocation retain];
		
		[anInvocation setTarget:target];
		[invocation retainArguments];
	}
}

- (id)prepareWithInvocationTarget:(id)aTarget {
	if (target != aTarget) {
		[target autorelease];
		target = [aTarget retain];
	}
	return self;
}

@end

@implementation ComparableInvocation 

- (id)initWithInvocation:(NSInvocation*)anInvocation {
	if ([super init]) {
		if (!(innerInvocation = [anInvocation retain]))
			return nil;
	}
	return self;
}
- (void)dealloc {
	[innerInvocation release];
	[super dealloc];
}

- (void)invoke {
	[innerInvocation invoke];
}

- (NSUInteger)hash {
	//this is alright for now
	return [[innerInvocation methodSignature] hash];
}

- (NSInvocation*)invocation {
	return innerInvocation;
}

- (BOOL)isEqual:(id)anObject {
	NSInvocation *anInvocation = [anObject invocation];
	
	//targets should have pointer equality to ensure they are the same object
	return [innerInvocation target] == [anInvocation target] && 
	[innerInvocation selector] == [anInvocation selector] &&
	[[innerInvocation methodSignature] isEqual:[anInvocation methodSignature]];
}

@end

@implementation NSInvocation (MissingMethods)

- (NSString*)description {
	return [NSString stringWithFormat:@"%@: %s", [self target], [self selector]];
}

@end
