/* DualField */

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

enum { BUTTON_HIDDEN, BUTTON_NORMAL, BUTTON_PRESSED };

@interface DualFieldCell : NSTextFieldCell {
	int clearButtonState, snapbackButtonState;
}

- (BOOL)snapbackButtonIsVisible;
- (void)setShowsSnapbackButton:(BOOL)shouldShow;

- (BOOL)clearButtonIsVisible;
- (void)setShowsClearButton:(BOOL)shouldShow;

- (NSRect)clearButtonRectForBounds:(NSRect)rect;
- (NSRect)snapbackButtonRectForBounds:(NSRect)rect;
- (NSRect)textAreaForBounds:(NSRect)rect;

- (BOOL)handleMouseDown:(NSEvent *)theEvent;

@end

@class NoteBookmark;

@interface DualField : NSTextField {
	IBOutlet NSTableView *notesTable;
	unsigned int lastLengthReplaced;
	NSString *snapbackString, *swappedOriginalString;
	
	NSToolTipTag docIconTag, textAreaTag, clearButtonTag;
	NSTrackingRectTag docIconRectTag;
	
	BOOL showsDocumentIcon;
	
	//cleared when doing a new manual search
	NSMutableArray *followedLinks;
	
	NSCursor *IBeamCursor;
	
	NSTimer *modifierTimer;
}

- (void)setTrackingRect;

- (void)setShowsDocumentIcon:(BOOL)showsIcon;
- (BOOL)showsDocumentIcon;

- (BOOL)hasFollowedLinks;
- (void)clearFollowedLinks;
- (void)pushFollowedLink:(NoteBookmark*)aBM;
- (NoteBookmark*)popLastFollowedLink;

- (void)setSnapbackString:(NSString*)string;
- (NSString*)snapbackString;
+ (NSImage*)snapbackImageWithString:(NSString*)string;

- (void)snapback:(id)sender;

- (unsigned int)lastLengthReplaced;

@end
