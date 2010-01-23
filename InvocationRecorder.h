//
//  InvocationRecorder.h
//  Notation
//
//  Created by Zachary Schneirov on 12/18/09.
//  Copyright 2009 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface InvocationRecorder : NSObject {
	id target;
	NSInvocation *invocation;
}

+ (id)invocationRecorder;
- (id)target;
- (NSInvocation *)invocation;
- (id)prepareWithInvocationTarget:(id)aTarget;

@end