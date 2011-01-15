/* MultiTextFinder */

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
#define Backward NO
#define Forward YES

@interface MultiTextFinder : NSObject
{
    IBOutlet NSButton *entirePhraseButton;
    IBOutlet NSTextField *findStringField;
    IBOutlet NSButton *ignoreCaseButton;
    IBOutlet NSButton *nextButton;
    IBOutlet NSButton *previousButton;
    IBOutlet NSPanel *window;
	id delegate;
	BOOL lastFindWasSuccessful, findStringChangedSinceLastPasteboardUpdate;
	NSString *findString;
}

- (void)setDelegate:(id)aDelegate;
- (id)delegate;

- (IBAction)changeEntirePhrase:(id)sender;
- (IBAction)findNext:(id)sender;
- (IBAction)findPrevious:(id)sender;
@end
