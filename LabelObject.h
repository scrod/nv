//
//  LabelObject.h
//  Notation
//
//  Created by Zachary Schneirov on 12/30/05.
//  Copyright 2005 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "NSString_NV.h"

@class NoteObject;

@interface LabelObject : NSObject {
    NSString *labelName, *lowercaseName;
    NSMutableSet *notes;
    
    unsigned int lowercaseHash;
}

force_inline NSString* titleOfLabel(LabelObject *label);
int compareLabel(const void *one, const void *two);

- (id)initWithTitle:(NSString*)name;
- (NSString*)title;
- (NSString*)associativeIdentifier;
- (void)setTitle:(NSString*)title;
- (void)addNote:(NoteObject*)note;
- (void)addNoteSet:(NSSet*)noteSet;
- (void)removeNote:(NoteObject*)note;
- (void)removeNoteSet:(NSSet*)noteSet;
- (NSSet*)noteSet;

- (BOOL)isEqual:(id)anObject;
- (unsigned)hash;

@end
