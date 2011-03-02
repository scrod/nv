//
//  AlienNoteImporter.h
//  Notation
//
//  Created by Zachary Schneirov on 11/15/06.

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

extern NSString *PasswordWasRetrievedFromKeychainKey;
extern NSString *RetrievedPasswordKey;

@class NotationController;
@class NotationPrefs;
@class NoteObject;

@interface AlienNoteImporter : NSObject {
	IBOutlet NSButton *grabCreationDatesButton;
	IBOutlet NSView *importAccessoryView;
	
	SEL importerSelector;
	
	//for URL downloading
	id receptionDelegate;
	
	id source;
	NSMutableDictionary *documentSettings;
	BOOL shouldGrabCreationDates;
}

//a directory containing notes, a custom bundle, or custom file format in which more than one note could be expected
- (id)initWithStoragePaths:(NSArray*)filenames;
- (id)initWithStoragePath:(NSString*)filename;
+ (void)importBlorOrHelpFilesIfNecessaryIntoNotation:(NotationController*)notation;
+ (AlienNoteImporter *)importerWithPath:(NSString*)path;
- (void)importNotesFromDialogAroundWindow:(NSWindow*)mainWindow receptionDelegate:(id)receiver;
- (void)importURLInBackground:(NSURL*)aURL linkTitle:(NSString*)linkTitle receptionDelegate:(id)receiver;
+ (NSString*)blorPath;

+ (NSBundle *)PDFKitBundle;
+ (Class)PDFDocClass;

- (NSView*)accessoryView;
- (NSDictionary*)documentSettings;
- (NSArray*)importedNotes;

- (NSArray*)notesWithPaths:(NSArray*)paths;
//where filename is a file expected to contain a single note (e.g., text, RTF, word)
- (NoteObject*)noteWithFile:(NSString*)filename;

- (NSArray*)notesInDirectory:(NSString*)filename;
- (NSArray*)notesInFile:(NSString*)filename;

@end

@interface AlienNoteImporter (DialogDelegate)
- (void)noteImporter:(AlienNoteImporter*)importer importedNotes:(NSArray*)notes;
@end