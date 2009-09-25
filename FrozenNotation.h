//
//  FrozenNotation.h
//  Notation
//
//  Created by Zachary Schneirov on 4/4/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class NotationPrefs;

@interface FrozenNotation : NSObject <NSCoding> {
	NSMutableArray *allNotes, *deletedNotes;
	NSMutableData *notesData;
	NotationPrefs *prefs;
}
- (id)initWithNotes:(NSMutableArray*)notes deletedNotes:(NSMutableArray*)antiNotes prefs:(NotationPrefs*)prefs;
+ (NSData*)frozenDataWithExistingNotes:(NSMutableArray*)notes 
						  deletedNotes:(NSMutableArray*)antiNotes 
								 prefs:(NotationPrefs*)prefs;
- (NSMutableArray*)unpackedNotesWithPrefs:(NotationPrefs*)somePrefs returningError:(OSStatus*)err;
- (NSMutableArray*)unpackedNotesReturningError:(OSStatus*)err;
- (NSMutableArray*)deletedNotes; //these won't need to be encrypted
- (NotationPrefs*)notationPrefs;

@end
