/* PassphraseRetriever */

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

@class NotationPrefs;

@interface PassphraseRetriever : NSObject
{
    IBOutlet NSTextField *helpStringField;
    IBOutlet NSButton *okButton, *differentFolderButton, *cancelButton;
    IBOutlet NSTextField *passphraseField;
    IBOutlet NSButton *rememberKeychainButton;
    IBOutlet NSPanel *window;
	NotationPrefs *notationPrefs;

}

+ (PassphraseRetriever *)retrieverWithNotationPrefs:(NotationPrefs*)prefs;
- (id)initWithNotationPrefs:(NotationPrefs*)prefs;
- (int)loadedUserPassphraseData;
- (IBAction)cancelAction:(id)sender;
- (IBAction)differentNotes:(id)sender;
- (IBAction)okAction:(id)sender;
@end
