//
//  InvocationRecorder.m
//  Notation
//
//  Created by Zachary Schneirov on 12/18/09.
//

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

@implementation NSInvocation (DescriptionCategory)

- (NSString*)description {
	return [NSString stringWithFormat:@"%@: %s", [self target], [self selector]];
}

@end