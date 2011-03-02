//
//  StickiesDocument.h
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


#import <Cocoa/Cocoa.h>

#if __LP64__
// Needed for compatability with data created by 32bit app
typedef struct _NSRect32 {
	struct {
		float x;
		float y;
	};
	struct {
		float width;
		float height;
	};
} NSRect32;
#else
typedef NSRect NSRect32;
#endif

@interface StickiesDocument : NSObject <NSCoding> {
    int mWindowColor;
    int mWindowFlags;
    NSRect32 mWindowFrame;
    NSData *mRTFDData;
    NSDate *mCreationDate;
    NSDate *mModificationDate;	
}

- (void)dealloc;
- (id)initWithCoder:(id)decoder;
- (void)encodeWithCoder:(id)coder;
- (NSDate *)creationDate;
- (NSDate *)modificationDate;
- (NSData*)RTFDData;
- (int)windowColor;
- (int)windowFlags;
- (NSRect32)windowFrame;

@end
