/* EncodingsManager */

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

@class NoteObject;

@interface EncodingsManager : NSObject
{
    IBOutlet NSPopUpButton *encodingsPopUpButton;
	IBOutlet NSButton *okButton;
    IBOutlet NSPanel *window;
	IBOutlet NSTextView *textView;
	IBOutlet NSTextField *helpStringField;
	
	NSStringEncoding currentEncoding;
	NoteObject *note;
	NSData *noteData;
	FSRef fsRef;
}

+ (EncodingsManager *)sharedManager;
- (BOOL)checkUnicode;
- (BOOL)tryToUpdateTextForEncoding:(NSStringEncoding)encoding;
- (BOOL)shouldUpdateNoteFromDisk;
- (void)showPanelForNote:(NoteObject*)aNote;
- (NSMenu*)textConversionsMenu;
- (IBAction)cancelAction:(id)sender;
- (IBAction)chooseEncoding:(id)sender;
- (IBAction)okAction:(id)sender;
@end
