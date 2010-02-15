//
//  StickiesDocument.m
//  Notation
//
//  Created by Zachary Schneirov on 11/15/06.

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
