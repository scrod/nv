//
//  InvocationRecorder.m
//  Notation
//

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */

#import "InvocationRecorder.h"

@interface InvocationRecorder ()
@property (nonatomic, retain, readwrite) id target;
@property (nonatomic, retain, readwrite) NSInvocation *invocation;
@end

@implementation InvocationRecorder

@synthesize target, invocation;

+ (id)invocationRecorder {
	return [[[self alloc] init] autorelease];
}

- (void)dealloc {
	[target release];
	[invocation release];
	[super dealloc];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSEL {
	//check the superclass first
	
	NSMethodSignature *theMethodSignature = [super methodSignatureForSelector:aSEL];
	return theMethodSignature ? theMethodSignature : [target methodSignatureForSelector:aSEL];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
	if (invocation != anInvocation) {
		self.invocation = anInvocation;
		
		[anInvocation setTarget:target];
		[invocation retainArguments];
	}
}

- (id)prepareWithInvocationTarget:(id)aTarget {
	if (target != aTarget) {
		self.target = aTarget;
	}
	return self;
}

@end

@implementation ComparableInvocation 

@synthesize invocation = innerInvocation;

- (id)initWithInvocation:(NSInvocation*)anInvocation {
	self = [super init];
	if (self) {
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
    return [NSString stringWithFormat:@"%@: %@", [self target], NSStringFromSelector([self selector])];
}

@end
