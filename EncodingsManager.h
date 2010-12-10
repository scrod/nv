/* EncodingsManager */

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
