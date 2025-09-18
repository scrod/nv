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


#import "ExporterManager.h"
#import "NoteObject.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "GlobalPrefs.h"

@implementation ExporterManager

@synthesize currentPanel;

+ (ExporterManager *)sharedManager {
	static ExporterManager *man = nil;
	if (!man)
		man = [[ExporterManager alloc] init];
	return man;
}

- (void)awakeFromNib {
	
	int storageFormat = [[[GlobalPrefs defaultPrefs] notationPrefs] notesStorageFormat];
	[formatSelectorPopup selectItemWithTag:storageFormat];
}

- (IBAction)formatSelectorChanged:(id)sender {
    NSSavePanel *panel = self.currentPanel;
    if (!panel) return; // Panel not yet shown or already dismissed

    NSInteger storageFormat = [[formatSelectorPopup selectedItem] tag];
    [panel setAllowedFileTypes:@[[NotationPrefs pathExtensionForFormat:(int)storageFormat]]];
}

- (void)exportPanelDidEnd:(NSSavePanel *)sheet returnCode:(int)returnCode contextInfo:(void  *)contextInfo {
	NSArray *notes = (NSArray *)contextInfo;
	if (returnCode == NSFileHandlingPanelOKButton && notes) {
		//write notes in chosen format
		NSUInteger i;
		NSInteger result, storageFormat = [[formatSelectorPopup selectedItem] tag];
		NSString *directory = nil, *filename = nil;
		BOOL overwriteNotes = NO;
		
		if ([sheet isKindOfClass:[NSOpenPanel class]]) {
			directory = [sheet filename];
		} else {
			filename = [[sheet filename] lastPathComponent];
			directory = [[sheet filename] stringByDeletingLastPathComponent];
			
			NSAssert([notes count] == 1, @"We returned from a save panel with more than one note?!");
			
			//user wanted us to overwrite this one--otherwise dialog would have been cancelled
			if ([[NSFileManager defaultManager] fileExistsAtPath:[sheet filename]]) overwriteNotes = YES;
			
			if ([filename compare:filenameOfNote([notes lastObject]) options:NSCaseInsensitiveSearch] != NSOrderedSame) {
				//undo any POSIX-safe crap NSSavePanel gave us--otherwise FSCreateFileUnicode will fail
				filename = [filename stringByReplacingOccurrencesOfString:@":" withString:@"/"];
			}
		}
		
		FSRef directoryRef;
		CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)directory, kCFURLPOSIXPathStyle, true);
		[(id)url autorelease];
		if (!url || !CFURLGetFSRef(url, &directoryRef)) {
			NSString *messageText = [NSString stringWithFormat:NSLocalizedString(@"The notes couldn't be exported because the directory quotemark%@quotemark couldn't be accessed.", nil),
				[directory stringByAbbreviatingWithTildeInPath]];
			NSAlert *alert = [[[NSAlert alloc] init] autorelease];
			[alert setMessageText:messageText];
			[alert setInformativeText:@""];
			[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
			[alert runModal];
			return;
		}
		
		//re-uniqify file names here (if [notes count] > 1)?
		
		for (i=0; i<[notes count]; i++) {
			BOOL lastNote = i != [notes count] - 1;
			NoteObject *note = [notes objectAtIndex:i];
			
        OSStatus err = [note exportToDirectoryRef:&directoryRef withFilename:filename usingFormat:(int)storageFormat overwrite:overwriteNotes];
			
			if (err == dupFNErr) {
				//ask about overwriting
				NSString *existingName = filename ? filename : filenameOfNote(note);
				existingName = [[existingName stringByDeletingPathExtension] stringByAppendingPathExtension:[NotationPrefs pathExtensionForFormat:(int)storageFormat]];
				NSAlert *alert = [[[NSAlert alloc] init] autorelease];
				[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"A file named quotemark%@quotemark already exists.", nil), existingName]];
				[alert setInformativeText:NSLocalizedString(@"Replace its current contents with that of the note?", @"replace the file's contents?")];
				[alert addButtonWithTitle:NSLocalizedString(@"Replace", nil)];
				[alert addButtonWithTitle:NSLocalizedString(@"Don't Replace", nil)];
				if (lastNote) {
					[alert addButtonWithTitle:NSLocalizedString(@"Replace All", nil)];
				}
				NSModalResponse response = [alert runModal];
				if (response == NSAlertFirstButtonReturn || response == NSAlertThirdButtonReturn) {
					if (response == NSAlertThirdButtonReturn) overwriteNotes = YES;
					err = [note exportToDirectoryRef:&directoryRef withFilename:filename usingFormat:(int)storageFormat overwrite:YES];
				} else {
					continue;
				}
			}
			if (err != noErr) {
				NSString *exportErrorTitleString = [NSString stringWithFormat:NSLocalizedString(@"The note quotemark%@quotemark couldn't be exported because %@.",nil), 
					titleOfNote(note), [NSString reasonStringFromCarbonFSError:err]];
				if (!lastNote) {
					NSAlert *errorAlert = [[[NSAlert alloc] init] autorelease];
					[errorAlert setMessageText:exportErrorTitleString];
					[errorAlert setInformativeText:@""];
					[errorAlert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
					[errorAlert runModal];
				} else {
					NSAlert *continueAlert = [[[NSAlert alloc] init] autorelease];
					[continueAlert setMessageText:exportErrorTitleString];
					[continueAlert setInformativeText:NSLocalizedString(@"Continue exporting?", @"alert title for exporter interruption")];
					[continueAlert addButtonWithTitle:NSLocalizedString(@"Continue", @"(exporting notes?)")];
					[continueAlert addButtonWithTitle:NSLocalizedString(@"Stop Exporting", @"(notes?)")];
					NSModalResponse continueResponse = [continueAlert runModal];
					if (continueResponse != NSAlertFirstButtonReturn) break;
				}
			}
		}
		
		FNNotify(&directoryRef, kFNDirectoryModifiedMessage, kFNNoImplicitAllSubscription);
		
		[notes release];
	}
}

- (void)exportNotes:(NSArray*)notes forWindow:(NSWindow*)window {
	
	if (!accessoryView) {
		if (![NSBundle loadNibNamed:@"ExporterManager" owner:self]) {
			NSLog(@"Failed to load ExporterManager.nib");
			NSBeep();
			return;
		}
	}
	
    if ([notes count] == 1) {
        NSSavePanel *savePanel = [NSSavePanel savePanel];
        self.currentPanel = savePanel;
        [savePanel setAccessoryView:accessoryView];
        [savePanel setCanCreateDirectories:YES];
        [savePanel setCanSelectHiddenExtension:YES];

        NSInteger storageFormat = [[formatSelectorPopup selectedItem] tag];
        [savePanel setAllowedFileTypes:@[[NotationPrefs pathExtensionForFormat:(int)storageFormat]]];

        NSString *filename = filenameOfNote([notes lastObject]);
        filename = [filename stringByDeletingPathExtension];
        filename = [filename stringByAppendingPathExtension:[NotationPrefs pathExtensionForFormat:(int)[[formatSelectorPopup selectedItem] tag]]];

        [savePanel setDirectoryURL:[NSURL fileURLWithPath:NSHomeDirectory()]];
        [savePanel setNameFieldStringValue:filename];

        NSArray *retainedNotes = [notes retain];
        [savePanel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
            int code = (response == NSModalResponseOK) ? NSFileHandlingPanelOKButton : NSFileHandlingPanelCancelButton;
            [self exportPanelDidEnd:savePanel returnCode:code contextInfo:(void *)retainedNotes];
            self.currentPanel = nil;
        }];

    } else if ([notes count] > 1) {
        NSOpenPanel *openPanel = [NSOpenPanel openPanel];
        self.currentPanel = openPanel;
        [openPanel setAccessoryView:accessoryView];
        [openPanel setCanCreateDirectories:YES];
        [openPanel setCanChooseFiles:NO];
        [openPanel setCanChooseDirectories:YES];
        [openPanel setPrompt:NSLocalizedString(@"Export",@"title of button to export notes from folder selection dialog")];
        [openPanel setTitle:NSLocalizedString(@"Export Notes", @"title of export notes dialog")];
        [openPanel setMessage:[NSString stringWithFormat:NSLocalizedString(@"Choose a folder into which %lu notes will be exported",nil), (unsigned long)[notes count]]];

        NSArray *retainedNotes = [notes retain];
        [openPanel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
            int code = (response == NSModalResponseOK) ? NSFileHandlingPanelOKButton : NSFileHandlingPanelCancelButton;
            [self exportPanelDidEnd:openPanel returnCode:code contextInfo:(void *)retainedNotes];
            self.currentPanel = nil;
        }];
    } else {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText:NSLocalizedString(@"No notes were selected for exporting.", nil)];
        [alert setInformativeText:NSLocalizedString(@"You must select at least one note to export.", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
        [alert runModal];
    }
}

- (void)dealloc {
    [currentPanel release];
    [super dealloc];
}

@end
