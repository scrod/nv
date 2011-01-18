//
//  DiskUUIDEntry.h
//  Notation
//
//  Created by Zachary Schneirov on 1/17/11.
//  Copyright 2011 Northwestern University. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface DiskUUIDEntry : NSObject {

	NSDate *lastAccessed;
	CFUUIDRef uuidRef;
}

- (id)initWithUUIDRef:(CFUUIDRef)aUUIDRef;
- (void)see;
- (CFUUIDRef)uuidRef;
- (NSDate*)lastAccessed;
@end
