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
	NSSavePanel *panel = (NSSavePanel *)[sender window];
	
	int storageFormat = [[formatSelectorPopup selectedItem] tag];
	[panel setRequiredFileType:[NotationPrefs pathExtensionForFormat:storageFormat]];
}

- (void)exportPanelDidEnd:(NSSavePanel *)sheet returnCode:(int)returnCode contextInfo:(void  *)contextInfo {
	NSArray *notes = (NSArray *)contextInfo;
	if (returnCode == NSFileHandlingPanelOKButton && notes) {
		//write notes in chosen format
		unsigned int i;
		int result, storageFormat = [[formatSelectorPopup selectedItem] tag];
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
			NSRunAlertPanel([NSString stringWithFormat:NSLocalizedString(@"The notes couldn't be exported because the directory quotemark%@quotemark couldn't be accessed.",nil),
				[directory stringByAbbreviatingWithTildeInPath]], @"", NSLocalizedString(@"OK",nil), nil, nil);
			return;
		}
		
		//re-uniqify file names here (if [notes count] > 1)?
		
		for (i=0; i<[notes count]; i++) {
			BOOL lastNote = i != [notes count] - 1;
			NoteObject *note = [notes objectAtIndex:i];
			
			OSStatus err = [note exportToDirectoryRef:&directoryRef withFilename:filename usingFormat:storageFormat overwrite:overwriteNotes];
			
			if (err == dupFNErr) {
				//ask about overwriting
				NSString *existingName = filename ? filename : filenameOfNote(note);
				existingName = [[existingName stringByDeletingPathExtension] stringByAppendingPathExtension:[NotationPrefs pathExtensionForFormat:storageFormat]];
				result = NSRunAlertPanel([NSString stringWithFormat:NSLocalizedString(@"A file named quotemark%@quotemark already exists.",nil), existingName],
										 NSLocalizedString(@"Replace its current contents with that of the note?", @"replace the file's contents?"),
										 NSLocalizedString(@"Replace",nil), NSLocalizedString(@"Don't Replace",nil), lastNote ? NSLocalizedString(@"Replace All",nil) : nil, nil);
				if (result == NSAlertDefaultReturn || result == NSAlertOtherReturn) {
					if (result == NSAlertOtherReturn) overwriteNotes = YES;
					err = [note exportToDirectoryRef:&directoryRef withFilename:filename usingFormat:storageFormat overwrite:YES];
				} else continue;
			}
			
			if (err != noErr) {
				NSString *exportErrorTitleString = [NSString stringWithFormat:NSLocalizedString(@"The note quotemark%@quotemark couldn't be exported because %@.",nil), 
					titleOfNote(note), [NSString reasonStringFromCarbonFSError:err]];
				if (!lastNote) {
					NSRunAlertPanel(exportErrorTitleString, @"", NSLocalizedString(@"OK",nil), nil, nil, nil);
				} else {
					result = NSRunAlertPanel(exportErrorTitleString, NSLocalizedString(@"Continue exporting?", @"alert title for exporter interruption"), 
											 NSLocalizedString(@"Continue", @"(exporting notes?)"), NSLocalizedString(@"Stop Exporting", @"(notes?)"), nil);
					if (result != NSAlertDefaultReturn) break;
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
		[savePanel setAccessoryView:accessoryView];
		[savePanel setCanCreateDirectories:YES];
		[savePanel setCanSelectHiddenExtension:YES];
		
		[self formatSelectorChanged:formatSelectorPopup];
		
		NSString *filename = filenameOfNote([notes lastObject]);
		filename = [filename stringByDeletingPathExtension];
		filename = [filename stringByAppendingPathExtension:[NotationPrefs pathExtensionForFormat:[[formatSelectorPopup selectedItem] tag]]];
			
		[savePanel beginSheetForDirectory:nil file:filename modalForWindow:window modalDelegate:self 
						   didEndSelector:@selector(exportPanelDidEnd:returnCode:contextInfo:) contextInfo:[notes retain]];
		
	} else if ([notes count] > 1) {
		NSOpenPanel *openPanel = [NSOpenPanel openPanel];
		[openPanel setAccessoryView:accessoryView];
		[openPanel setCanCreateDirectories:YES];
		[openPanel setCanChooseFiles:NO];
		[openPanel setCanChooseDirectories:YES];
		[openPanel setPrompt:NSLocalizedString(@"Export",@"title of button to export notes from folder selection dialog")];
		[openPanel setTitle:NSLocalizedString(@"Export Notes", @"title of export notes dialog")];
		[openPanel setMessage:[NSString stringWithFormat:NSLocalizedString(@"Choose a folder into which %d notes will be exported",nil), [notes count]]];

		[openPanel beginSheetForDirectory:nil file:nil types:nil modalForWindow:window modalDelegate:self 
						   didEndSelector:@selector(exportPanelDidEnd:returnCode:contextInfo:) contextInfo:[notes retain]];
	} else {
		NSRunAlertPanel(NSLocalizedString(@"No notes were selected for exporting.",nil), 
						NSLocalizedString(@"You must select at least one note to export.",nil), NSLocalizedString(@"OK",nil), NULL, NULL);
	}
}

@end
