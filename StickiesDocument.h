//
//  StickiesDocument.h
//  Notation
//
//  Created by Zachary Schneirov on 11/15/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface StickiesDocument : NSObject <NSCoding> {
    int mWindowColor;
    int mWindowFlags;
    NSRect mWindowFrame;
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
- (NSRect)windowFrame;

@end
