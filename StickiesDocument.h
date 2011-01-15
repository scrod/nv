//
//  StickiesDocument.h
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
