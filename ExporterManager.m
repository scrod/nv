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
#import "NSFileManager_NV.h"

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

- (void)exportPanelDidEnd:(NSSavePanel *)panel returnCode:(NSModalResponse)returnCode contextInfo:(void  *)contextInfo {
	NSArray *notes = (NSArray *)contextInfo;
	if (!notes || returnCode != NSModalResponseOK) {
		return;
	}

	//write notes in chosen format
	NSUInteger i;
	NSInteger storageFormat = [[formatSelectorPopup selectedItem] tag];
	NSURL *directoryURL = nil;
	NSString *filename = nil;
	BOOL overwriteNotes = NO;

	if ([panel isKindOfClass:[NSOpenPanel class]]) {
		directoryURL = [[(NSOpenPanel *)panel URLs] firstObject];
	} else {
		NSURL *fileURL = [panel URL];
		if (!fileURL) {
			NSBeep();
			return;
		}
		filename = [fileURL lastPathComponent];
		directoryURL = [fileURL URLByDeletingLastPathComponent];
		NSAssert([notes count] == 1, @"We returned from a save panel with more than one note?!");
		overwriteNotes = [fileURL checkResourceIsReachableAndReturnError:NULL];
		if ([filename compare:filenameOfNote([notes lastObject]) options:NSCaseInsensitiveSearch] != NSOrderedSame) {
			filename = [filename stringByReplacingOccurrencesOfString:@":" withString:@"/"];
		}
	}

	NSURL *directoryReferenceURL = [[NSFileManager defaultManager] fileReferenceURLForURL:directoryURL error:NULL];
	if (!directoryReferenceURL) {
		NSBeep();
		return;
	}


	//re-uniqify file names here (if [notes count] > 1)?
	for (i=0; i<[notes count]; i++) {
		BOOL lastNote = i != [notes count] - 1;
		NoteObject *note = [notes objectAtIndex:i];
			
		OSStatus err = [note exportToDirectoryURL:directoryReferenceURL withFilename:filename usingFormat:(int)storageFormat overwrite:overwriteNotes];
			
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
				err = [note exportToDirectoryURL:directoryReferenceURL withFilename:filename usingFormat:(int)storageFormat overwrite:YES];
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
}

- (void)exportNotes:(NSArray*)notes forWindow:(NSWindow*)window {
	
	if (!accessoryView) {
		NSArray *topLevelObjects = nil;
		if (![[NSBundle mainBundle] loadNibNamed:@"ExporterManager" owner:self topLevelObjects:&topLevelObjects]) {
			NSLog(@"Failed to load ExporterManager.nib");
			NSBeep();
			return;
		}
		[exporterTopLevelObjects release];
		exporterTopLevelObjects = [topLevelObjects retain];
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

		[savePanel setDirectoryURL:[[NSFileManager defaultManager] homeDirectoryForCurrentUser]];
        [savePanel setNameFieldStringValue:filename];

        NSArray *retainedNotes = [notes retain];
        [savePanel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
            [self exportPanelDidEnd:savePanel returnCode:response contextInfo:(void *)retainedNotes];
            [retainedNotes release];
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
            [self exportPanelDidEnd:openPanel returnCode:response contextInfo:(void *)retainedNotes];
            [retainedNotes release];
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
    [exporterTopLevelObjects release];
    [super dealloc];
}

@end
