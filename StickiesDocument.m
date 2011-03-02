//
//  StickiesDocument.m
//  Notation
//
//  Created by Zachary Schneirov on 11/15/06.

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
