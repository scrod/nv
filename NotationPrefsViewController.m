//
//  NotationPrefsViewController.m
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


#import "GlobalPrefs.h"
#import "NotationPrefsViewController.h"
#import "InvocationRecorder.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "NSCollection_utils.h"
#import "SyncResponseFetcher.h"
#import "PassphrasePicker.h"
#import "PassphraseChanger.h"
#import "ExternalEditingSession/ExternalEditingSession.h"

@interface NotationPrefsViewController ()
- (void)_finishExternalEditingForAction:(NSString*)action
	informativeText:(NSString*)informativeText continuation:(void (^)(void))continuation;
- (void)_changedFileStorageFormat:(id)sender skipEncryptionWarning:(BOOL)skipWarning;
@end

@implementation FileKindListView 

- (BOOL)acceptsFirstResponder {
    
    if (storageFormatPopupButton)
		return ([storageFormatPopupButton selectedTag] != SingleDatabaseFormat);
	
    return YES;
}
@end

enum {VERIFY_NOT_ATTEMPTED, VERIFY_FAILED, VERIFY_IN_PROGRESS, VERIFY_SUCCESS};

@implementation NotationPrefsViewController

- (NSView*)view {
    if (!view) {
		NSArray *topLevelObjects = nil;
		if (![[NSBundle mainBundle] loadNibNamed:@"NotationPrefsView" owner:self topLevelObjects:&topLevelObjects])  {
			NSLog(@"Failed to load NotationPrefsView.nib");
			return nil;
		}
		[notationPrefsTopLevelObjects release];
		notationPrefsTopLevelObjects = [topLevelObjects retain];
    }
    
    return view;
}

- (id)init {
    self = [super init];
    if (self) {
		didAwakeFromNib = NO;
		notationPrefs = [[[GlobalPrefs defaultPrefs] notationPrefs] retain];
		
		disableEncryptionString = NSLocalizedString(@"Turn Off Note Encryption...",nil);
		enableEncryptionString = NSLocalizedString(@"Turn On Note Encryption...",nil);
	
		[[GlobalPrefs defaultPrefs] registerForSettingChange:@selector(setNotationPrefs:sender:) withTarget:self];
    }
    return self;
}
- (void)dealloc {
	[passphrasePicker release];
	[changer release];
	[notationPrefs release];
	[postStorageFormatInvocation release];
	[notationPrefsTopLevelObjects release];
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[super dealloc];
}

- (void)awakeFromNib {
    didAwakeFromNib = YES;
    [allowedExtensionsTable setDataSource:self];
    [allowedExtensionsTable setDelegate:self];
	[[allowedTypesTable enclosingScrollView] setHidden:YES];
	[newTypeButton setHidden:YES];
	[removeTypeButton setHidden:YES];
	
	
	//this additional management for sync prefs, plus the need for per-service settings and externally triggering updates really demands its own class
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(initializeControls) name:NotationPrefsDidChangeNotification object:nil];

    [self initializeControls];
}

- (BOOL)tableView:(NSTableView *)aTableView shouldEditTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	return (notationPrefs && [notationPrefs notesStorageFormat]);
}
- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex {
    return (notationPrefs && [notationPrefs notesStorageFormat]);
}
- (void)tableViewSelectionDidChange:(NSNotification *)aNotification {
	NSTableView *tv = [aNotification object];
	BOOL isRowSelected = [tv selectedRow] > -1;
	
	if (tv == allowedExtensionsTable) {
		[removeExtensionButton setEnabled:isRowSelected];
		[makeDefaultExtensionButton setEnabled:isRowSelected];
	}
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
	
	
	if ([selectorString isEqualToString:SEL_STR(setNotationPrefs:sender:)]) {
		
		//force these objects to re-init with the new notationprefs
		[changer release]; changer = nil;
		[passphrasePicker release]; passphrasePicker = nil;
		
		[notationPrefs release];
		notationPrefs = [[[GlobalPrefs defaultPrefs] notationPrefs] retain];
		
		if (didAwakeFromNib)
			[self initializeControls];
	}
}

- (void)initializeControls {
    //set up outlets to reflect new settings
    if (notationPrefs) {
		
		[keyLengthField setIntValue:[notationPrefs keyLengthInBits]];
		[keyLengthStepper setIntValue:[notationPrefs keyLengthInBits]];
		[self setEncryptionControlsState:[notationPrefs doesEncryption]];
		[self setSeparateFileControlsState:[notationPrefs notesStorageFormat]];
		[self updateRemoveKeychainItemStatus];
		[confirmFileDeletionButton setState:[notationPrefs confirmFileDeletion]];
		[secureTextEntryButton setState:[notationPrefs secureTextEntry]];
		
		[allowedExtensionsTable reloadData];
    }
}

- (void)setEncryptionControlsState:(BOOL)encryptionState {
    [enableEncryptionButton setTitle:(encryptionState ? disableEncryptionString : enableEncryptionString)];
    [changePasswordButton setEnabled:encryptionState];
	[passwordSettingsMatrix setEnabled:encryptionState];
	
	[passwordSettingsMatrix setState:[notationPrefs storesPasswordInKeychain] atRow:0 column:0];
	[passwordSettingsMatrix setState:![notationPrefs storesPasswordInKeychain] atRow:1 column:0];
	
    [keyLengthField setEnabled:encryptionState];
    [keyLengthStepper setEnabled:encryptionState];
}

- (void)setSeparateFileControlsState:(BOOL)separateFileControlsState {
	[newExtensionButton setEnabled:separateFileControlsState];
	[removeExtensionButton setEnabled:separateFileControlsState && [allowedExtensionsTable selectedRow] > -1];
	[makeDefaultExtensionButton setEnabled:separateFileControlsState && [allowedExtensionsTable selectedRow] > -1];
	[allowedExtensionsTable setEnabled:separateFileControlsState];
	
	[confirmFileDeletionButton setEnabled:separateFileControlsState];
	
	[storageFormatPopupButton selectItemWithTag:[notationPrefs notesStorageFormat]];
	
	[fileAttributesHelpText setTextColor: separateFileControlsState ? [NSColor controlTextColor] : [NSColor grayColor]];	
}

- (void)updateRemoveKeychainItemStatus {
	
	if (![removeFromKeychainButton isHidden]) {
		SecKeychainItemRef itemRef = [notationPrefs currentKeychainItem];
		
		[removeFromKeychainButton setEnabled:(itemRef != NULL)];
		
		if (itemRef)
			CFRelease(itemRef);
	}
}

- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject 
   forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {

	if (aTableView == allowedExtensionsTable) {
		if (![notationPrefs setExtension:anObject atIndex:(unsigned int)rowIndex])
			[self removedExtension:self];
	}
}


- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {

	if (aTableView == allowedExtensionsTable) {
			NSString *extension = [notationPrefs pathExtensionAtIndex:(int)rowIndex];
		
		if ([notationPrefs indexOfChosenPathExtension] == (unsigned int)rowIndex) {
			return [[[NSAttributedString alloc] initWithString:extension attributes:
					[NSDictionary dictionaryWithObjectsAndKeys:
					 [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]], NSFontAttributeName, nil]] autorelease];
		}
		return extension;
			
	}
	return 0;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
	if (aTableView == allowedExtensionsTable)
		return [notationPrefs pathExtensionsCount];
	return 0;
}

- (IBAction)addedExtension:(id)sender {
    [notationPrefs addAllowedPathExtension:@""];
	[allowedExtensionsTable reloadData];
	
	[allowedExtensionsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:[notationPrefs pathExtensionsCount]-1] byExtendingSelection:NO];
	[allowedExtensionsTable editColumn:0 row:[notationPrefs pathExtensionsCount]-1 withEvent:nil select:YES];
}

- (IBAction)addedType:(id)sender {
	(void)sender;
}

- (IBAction)changedKeyLength:(id)sender {
    
    int bits = [keyLengthStepper intValue];
    [keyLengthField setIntValue:bits];
    [notationPrefs setKeyLengthInBits:bits];
}

- (IBAction)changedKeychainSettings:(id)sender {
	//matrix does not change until the next runloop iteration, apparently
	if (sender != self)
		[self performSelector:@selector(changedKeychainSettings:) withObject:self afterDelay:0.0];
	else
		[notationPrefs setStoresPasswordInKeychain:[[passwordSettingsMatrix cellAtRow:0 column:0] state]];
		
}

- (IBAction)changedFileDeletionWarningSettings:(id)sender {
    [notationPrefs setConfirmsFileDeletion:[confirmFileDeletionButton state]];
}

- (IBAction)removeFromKeychain:(id)sender {
	[notationPrefs removeKeychainData];

	[self updateRemoveKeychainItemStatus];
}

- (int)notesStorageFormatInProgress {
	return notesStorageFormatInProgress;
}

- (void)runQueuedStorageFormatChangeInvocation {
	[postStorageFormatInvocation invoke];
	[postStorageFormatInvocation release];
	postStorageFormatInvocation = nil;
}

- (void)notesStorageFormatDidChange {
	int actualFormat = [notationPrefs notesStorageFormat];
	if (notesStorageFormatInProgress != actualFormat) {
		[postStorageFormatInvocation release];
		postStorageFormatInvocation = nil;
	}
	notesStorageFormatInProgress = actualFormat;
	[self setSeparateFileControlsState:notesStorageFormatInProgress];
	
    [allowedExtensionsTable reloadData];
}

- (IBAction)changedFileStorageFormat:(id)sender {
	[self _changedFileStorageFormat:sender skipEncryptionWarning:NO];
}

- (void)_changedFileStorageFormat:(id)sender skipEncryptionWarning:(BOOL)skipWarning {
	    NSInteger storageTag = [storageFormatPopupButton selectedTag];
	if ([[ExternalEditingSession sharedExternalEditingSession] activeScratchEditingSessionCount]) {
		NSString *additionalWarning = storageTag != SingleDatabaseFormat &&
			[notationPrefs doesEncryption] ? NSLocalizedString(
			@" Encryption will also be disabled and notes will be written to disk in clear text.", nil) : @"";
		NSString *information = [NSLocalizedString(
			@"Notational Velocity will preserve changes saved so far, then remove its temporary files. Later changes made in an external editor's remaining buffer cannot be recovered.", nil)
			stringByAppendingString:additionalWarning];
		[self _finishExternalEditingForAction:NSLocalizedString(@"Change Storage Format", nil)
			informativeText:information continuation:^{
				[self _changedFileStorageFormat:sender skipEncryptionWarning:YES];
			}];
		return;
	}
	
	if (storageTag != SingleDatabaseFormat && [notationPrefs doesEncryption]) {
		if (skipWarning) {
			[self _disableEncryption];
		} else {
		NSAlert *encryptionAlert = [[[NSAlert alloc] init] autorelease];
		[encryptionAlert setMessageText:NSLocalizedString(@"Encryption is currently on, but storing notes individually requires it to be off. Disable encryption?", nil)];
		[encryptionAlert setInformativeText:NSLocalizedString(@"Warning: Your notes will be written to disk in clear text.", nil)];
		[encryptionAlert addButtonWithTitle:NSLocalizedString(@"Disable Encryption", nil)];
		[encryptionAlert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
		NSModalResponse encryptionResponse = [encryptionAlert runModal];
		if (encryptionResponse == NSAlertFirstButtonReturn) {
			//disable encryption
			[self disableEncryptionWithWarning:NO];
		} else {
			//cancelled
			[self notesStorageFormatDidChange];
			return;
		}
		}
	}
	
	notesStorageFormatInProgress = (int)storageTag;
	
	//if we're changing to a database format from a non-database-format, ask to trash existing files
    if ([notationPrefs shouldDisplaySheetForProposedFormat:notesStorageFormatInProgress]) {
		
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:NSLocalizedString(@"Individual files remain in the notes directory. Leave them alone or move them to the Trash?", nil)];
		[alert setInformativeText:NSLocalizedString(@"When notes are stored in a single database individual files become redundant.", nil)];
		[alert addButtonWithTitle:NSLocalizedString(@"Keep Files", @"button title for not discarding note files")];
		[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
		[alert setAlertStyle:NSAlertStyleWarning];
		[alert addButtonWithTitle:NSLocalizedString(@"Move to Trash", @"button title for trashing notes")];
		
		[alert beginSheetModalForWindow:[view window] completionHandler:^(NSModalResponse response) {
			[notationPrefs noteFilesCleanupSheetDidEnd:[alert window] returnCode:(int)response contextInfo:self];
		}];
		//will ultimately call -notesStorageFormatDidChange
	} else {
		//just call setNotesStorageFormat straight-out
		[notationPrefs setNotesStorageFormat:notesStorageFormatInProgress];
		BOOL formatChanged = [notationPrefs notesStorageFormat] == notesStorageFormatInProgress;
		[self notesStorageFormatDidChange];
		
		//sheet ending will not do this for us--there is no sheet
		if (formatChanged) [self runQueuedStorageFormatChangeInvocation];
	}
}

- (IBAction)changedSecureTextEntry:(id)sender {
	[notationPrefs setSecureTextEntry:[secureTextEntryButton state]];
}

- (IBAction)changePassphrase:(id)sender {
	
	NSAssert([notationPrefs doesEncryption], @"Encryption must be on before the password can be changed.");
	if ([[ExternalEditingSession sharedExternalEditingSession] activeScratchEditingSessionCount]) {
		[self _finishExternalEditingForAction:NSLocalizedString(@"Change Passphrase", nil)
			informativeText:nil continuation:^{ [self changePassphrase:sender]; }];
		return;
	}
	
	if (!changer) changer = [[PassphraseChanger alloc] initWithNotationPrefs:notationPrefs];
	[changer showAroundWindow:[view window]];
}

- (IBAction)makeDefaultExtension:(id)sender {
	[[allowedExtensionsTable window] makeFirstResponder:allowedExtensionsTable];
	
	NSInteger selectedRow = [allowedExtensionsTable selectedRow];
	if (selectedRow > -1)
		[notationPrefs setChosenPathExtensionAtIndex:(unsigned int)selectedRow];
	
	[allowedExtensionsTable reloadData];	
}

- (IBAction)removedExtension:(id)sender {
	[allowedExtensionsTable abortEditing];
	
	NSInteger selectedRow = [allowedExtensionsTable selectedRow];
	if (selectedRow > -1)
			if (![notationPrefs removeAllowedPathExtensionAtIndex:(unsigned int)selectedRow]) NSBeep();
	
	[allowedExtensionsTable reloadData];
}

- (IBAction)removedType:(id)sender {
	(void)sender;
}

- (void)passphrasePicker:(PassphrasePicker*)picker choseAPassphrase:(BOOL)success {
	
	[self setEncryptionControlsState:success];
	[notationPrefs setDoesEncryption:success];
	[self updateRemoveKeychainItemStatus];
}

- (void)encryptionFormatMismatchSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	if (returnCode == NSAlertFirstButtonReturn) {
		//switching to single DB
		[storageFormatPopupButton selectItemWithTag:SingleDatabaseFormat];
		
		[self changedFileStorageFormat:storageFormatPopupButton];
		
		//need to show PW picker dialog after this ->
		
		//[picker showAroundWindow:[view window] resultDelegate:self];
		
		[postStorageFormatInvocation release];
		
		//so queue it up:
		InvocationRecorder *invRecorder = [InvocationRecorder invocationRecorder];
		[[invRecorder prepareWithInvocationTarget:passphrasePicker] showAroundWindow:[view window] resultDelegate:self];
		postStorageFormatInvocation = [[invRecorder invocation] retain];
	}
}

- (void)enableEncryption {
	if ([[ExternalEditingSession sharedExternalEditingSession] activeScratchEditingSessionCount]) {
		[self _finishExternalEditingForAction:NSLocalizedString(@"Enable Encryption", nil)
			informativeText:nil continuation:^{ [self enableEncryption]; }];
		return;
	}
	if (!passphrasePicker) passphrasePicker = [[PassphrasePicker alloc] initWithNotationPrefs:notationPrefs];
	
	int format = [notationPrefs notesStorageFormat];
	if (format == SingleDatabaseFormat) {
		
		[passphrasePicker showAroundWindow:[view window] resultDelegate:self];
	} else {
		NSString *formatStrings[] = { NSLocalizedString(@"(WHAT??)",@"user shouldn't see this"), 
			NSLocalizedString(@"plain text",nil), NSLocalizedString(@"rich text",nil), NSLocalizedString(@"HTML",nil) };
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Your notes are currently stored as %@ files on disk, but encryption requires a single database. Switch to a database format?", nil), formatStrings[format]]];
		[alert setInformativeText:NSLocalizedString(@"Notational Velocity supports encryption only for notes stored in a database file.", nil)];
		[alert addButtonWithTitle:NSLocalizedString(@"Use a single database file", nil)];
		[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
		[alert setAlertStyle:NSAlertStyleWarning];
		
		[alert beginSheetModalForWindow:[view window] completionHandler:^(NSModalResponse response) {
			[self encryptionFormatMismatchSheetDidEnd:[alert window] returnCode:(int)response contextInfo:NULL];
		}];
	}
}

- (void)disableEncryptionWarningSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	if (returnCode == NSAlertFirstButtonReturn) {
		[self _disableEncryption];
	}
}

- (void)_disableEncryption {
	[self setEncryptionControlsState:NO];
	[notationPrefs setDoesEncryption:NO];
	[self updateRemoveKeychainItemStatus];
	
	[passphrasePicker release]; passphrasePicker = nil;
}

- (void)disableEncryptionWithWarning:(BOOL)warning {
	if ([notationPrefs doesEncryption]) {
		if ([[ExternalEditingSession sharedExternalEditingSession] activeScratchEditingSessionCount]) {
			NSString *information = NSLocalizedString(
				@"Notational Velocity will preserve changes saved so far, then remove its temporary files. Later changes made in an external editor's remaining buffer cannot be recovered. Notes will then be written to disk in clear text.", nil);
			[self _finishExternalEditingForAction:NSLocalizedString(@"Disable Encryption", nil)
				informativeText:information continuation:^{ [self _disableEncryption]; }];
			return;
		}
		if (warning) {
			NSAlert *alert = [[[NSAlert alloc] init] autorelease];
			[alert setMessageText:NSLocalizedString(@"Disable note encryption now?", nil)];
			[alert setInformativeText:NSLocalizedString(@"Warning: Your notes will be written to disk in clear text.", nil)];
			[alert addButtonWithTitle:NSLocalizedString(@"Disable Encryption", @"button title for disabling note encryption")];
			[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
			[alert setAlertStyle:NSAlertStyleWarning];
			
			[alert beginSheetModalForWindow:[view window] completionHandler:^(NSModalResponse response) {
				[self disableEncryptionWarningSheetDidEnd:[alert window] returnCode:(int)response contextInfo:NULL];
			}];
			
		} else {
			[self _disableEncryption];
		}
		
	} else {
		NSLog(@"Not disabling encryption because it is already off.");
	}
}

- (void)_finishExternalEditingForAction:(NSString*)action
	informativeText:(NSString*)informativeText continuation:(void (^)(void))continuation {
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(
		@"%@ and end external editing?", nil), action]];
	[alert setInformativeText:informativeText ?: NSLocalizedString(
		@"Notational Velocity will preserve changes saved so far, then remove its temporary files. Later changes made in an external editor's remaining buffer cannot be recovered.", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Continue", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
	[alert setAlertStyle:NSAlertStyleWarning];
	if ([alert runModal] != NSAlertFirstButtonReturn) return;
	void (^next)(void) = [continuation copy];
	ExternalEditingSession *editor = [ExternalEditingSession sharedExternalEditingSession];
	[editor beginScratchEditingSuspension];
	[editor finishAllScratchEditingSessionsWithCompletionHandler:
		^(BOOL success) {
			if (success) next();
			else {
				NSAlert *failure = [[[NSAlert alloc] init] autorelease];
				[failure setMessageText:NSLocalizedString(@"External editing could not be finished.", nil)];
				[failure setInformativeText:NSLocalizedString(
					@"The settings change was canceled. The temporary file and external-editing session remain available; save again and retry.", nil)];
				[failure addButtonWithTitle:NSLocalizedString(@"OK", nil)];
				[failure setAlertStyle:NSAlertStyleCritical];
				[failure runModal];
			}
			[next release];
			[editor endScratchEditingSuspension];
		}];
}

- (IBAction)toggledEncryption:(id)sender {
	BOOL encryptionOn = ![notationPrefs doesEncryption];
	
	if (encryptionOn) {
		[self enableEncryption];
	} else {
		[self disableEncryptionWithWarning:YES];
	}
}

@end
