/* DualField */

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
