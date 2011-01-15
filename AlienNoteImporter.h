//
//  AlienNoteImporter.h
//  Notation
//
//  Created by Zachary Schneirov on 11/15/06.

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