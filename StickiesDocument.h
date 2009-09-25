//
//  StickiesDocument.h
//  Notation
//
//  Created by Zachary Schneirov on 11/15/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

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
