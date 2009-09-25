//
//  StickiesDocument.m
//  Notation
//
//  Created by Zachary Schneirov on 11/15/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import "StickiesDocument.h"

@implementation StickiesDocument

- (void)dealloc {
	
	[mRTFDData release];
	[mCreationDate release];
	[mModificationDate release];
	
	[super dealloc];
}

/*
 int mWindowColor;
 int mWindowFlags;
 NSRect mWindowFrame;
 NSData *mRTFDData;
 NSDate *mCreationDate;
 NSDate *mModificationDate;
*/

- (id)initWithCoder:(id)decoder {
	[super init];
	
	mRTFDData = [[decoder decodeObject] retain];
	[decoder decodeValueOfObjCType:@encode(int) at:&mWindowFlags];
#if __LP64__
	[decoder decodeValueOfObjCType:"{_NSRect={_NSPoint=ff}{_NSSize=ff}}" at:&mWindowFrame];
#else
	[decoder decodeValueOfObjCType:@encode(NSRect) at:&mWindowFrame];
#endif
	[decoder decodeValueOfObjCType:@encode(int) at:&mWindowColor];
	mCreationDate = [[decoder decodeObject] retain];
	mModificationDate = [[decoder decodeObject] retain];
	
	return self;
}

- (void)encodeWithCoder:(id)coder {
	NSAssert(0, @"Notational Velocity is not supposed to make stickies!");
}

- (NSDate *)creationDate {
	return mCreationDate;
}

- (NSDate *)modificationDate {
	return mModificationDate;
}

- (NSData*)RTFDData {
	return mRTFDData;
}

- (int)windowColor {
	return mWindowColor;
}

- (int)windowFlags {
	return mWindowFlags;
}

- (NSRect32)windowFrame {
	return mWindowFrame;
}

@end
