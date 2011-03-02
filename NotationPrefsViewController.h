//
//  NotationPrefsViewController.h
//  Notation
//
//  Created by Zachary Schneirov on 4/1/06.

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

@class NotationPrefs;
@class PassphrasePicker;
@class PassphraseChanger;
@class SyncResponseFetcher;

@interface FileKindListView : NSTableView {
    IBOutlet NSPopUpButton *storageFormatPopupButton;
}
@end

@interface NotationPrefsViewController : NSObject 
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6
<NSTableViewDelegate, NSTableViewDataSource>
#endif
{
    IBOutlet NSTableView *allowedExtensionsTable;
    IBOutlet NSTableView *allowedTypesTable;
	IBOutlet NSButton *enableEncryptionButton;
    IBOutlet NSButton *changePasswordButton;
    IBOutlet NSStepper *keyLengthStepper;
    IBOutlet NSTextField *keyLengthField, *fileAttributesHelpText;
    IBOutlet NSButton *newExtensionButton;
    IBOutlet NSButton *newTypeButton;
    IBOutlet NSTextField *syncAccountField;
    IBOutlet NSTextField *syncPasswordField;
	IBOutlet NSButton *makeDefaultExtensionButton;
    IBOutlet NSButton *removeExtensionButton;
    IBOutlet NSButton *removeTypeButton;
    IBOutlet NSButton *confirmFileDeletionButton;
	IBOutlet NSButton *secureTextEntryButton;
	IBOutlet NSButton *removeFromKeychainButton;
    IBOutlet NSPopUpButton *storageFormatPopupButton;
    IBOutlet NSMatrix *passwordSettingsMatrix;
    IBOutlet NSWindow *webOptionsWindow;
	IBOutlet NSButton *enabledSyncButton;
	IBOutlet NSImageView *verifyStatusImageView;
	IBOutlet NSTextField *verifyStatusField;
	IBOutlet NSPopUpButton *syncingFrequency;
	IBOutlet NSImageView *syncEncAlertView;
	IBOutlet NSTextField *syncEncAlertField;
    
    IBOutlet NSView *view;

	BOOL didAwakeFromNib;
    
	NSInvocation *postStorageFormatInvocation;
	int notesStorageFormatInProgress;
    NotationPrefs *notationPrefs;
	
	PassphrasePicker *picker;
	PassphraseChanger *changer;

	BOOL verificationAttempted;
	SyncResponseFetcher *loginVerifier;
	
	NSString *disableEncryptionString, *enableEncryptionString;
}

- (NSView*)view;
- (void)setSyncControlsState:(BOOL)syncState;
- (void)setEncryptionControlsState:(BOOL)encryptionState;
- (void)setSeparateFileControlsState:(BOOL)separateFileControlsState;
- (void)initializeControls;

- (IBAction)addedExtension:(id)sender;
- (IBAction)addedType:(id)sender;
- (IBAction)changedKeyLength:(id)sender;
- (IBAction)changedKeychainSettings:(id)sender;
- (IBAction)changedFileDeletionWarningSettings:(id)sender;
- (IBAction)changedFileStorageFormat:(id)sender;
- (IBAction)changePassphrase:(id)sender;
- (IBAction)changedSecureTextEntry:(id)sender;
- (IBAction)removeFromKeychain:(id)sender;
- (void)updateRemoveKeychainItemStatus;
- (void)notesStorageFormatDidChange;
- (int)notesStorageFormatInProgress;
- (void)runQueuedStorageFormatChangeInvocation;
- (IBAction)visitSimplenoteSite:(id)sender;
- (IBAction)makeDefaultExtension:(id)sender;
- (IBAction)removedExtension:(id)sender;
- (IBAction)removedType:(id)sender;

- (IBAction)toggledSyncing:(id)sender;
- (IBAction)syncFrequencyChange:(id)sender;

- (void)startVerifyingAfterDelay;
- (void)startLoginVerifier;
- (void)cancelLoginVerifier;
- (void)setVerificationStatus:(int)status withString:(NSString*)aString;

- (void)encryptionFormatMismatchSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode 
								contextInfo:(void *)contextInfo;
- (IBAction)toggledEncryption:(id)sender;
- (void)enableEncryption;
- (void)_disableEncryption;
- (void)disableEncryptionWithWarning:(BOOL)warning;
@end
