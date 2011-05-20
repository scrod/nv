//
//  ExternalEditorListController.h
//  Notation
//
//  Created by Zachary Schneirov on 3/14/11.

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

extern NSString *ExternalEditorsChangedNotification;

@class NoteObject;

@interface ExternalEditor : NSObject {

	BOOL installCheckFailed;
	NSImage *iconImg;
	NSString *bundleIdentifier;
	NSURL *resolvedURL;
	NSString *displayName;
	NSMutableDictionary *knownPathExtensions;
}

- (id)initWithBundleID:(NSString*)aBundleIdentifier resolvedURL:(NSURL*)aURL;
- (BOOL)canEditNoteDirectly:(NoteObject*)aNote;
- (BOOL)canEditAllNotes:(NSArray*)notes;
- (NSImage*)iconImage;
- (NSURL*)resolvedURL;
- (NSString*)displayName;
- (BOOL)isInstalled;
- (BOOL)isODBEditor;
- (NSString*)bundleIdentifier;

@end

@interface ExternalEditorListController : NSObject {

	NSMutableArray *userEditorList;
	NSArray *ODBEditorList;
	ExternalEditor *defaultEditor;
	
	NSMutableSet *editNotesMenus, *editorPrefsMenus;
	
	NSMutableArray *_installedODBEditors;
}
- (id)initWithUserDefaults;
+ (ExternalEditorListController*)sharedInstance;
- (void)addUserEditorFromDialog:(id)sender;
- (void)resetUserEditors:(id)sender;
- (void)_initDefaults;
- (NSArray*)_installedODBEditors;
- (BOOL)editorIsMember:(ExternalEditor*)anEditor;
+ (NSSet*)ODBAppIdentifiers;
- (NSArray*)userEditorIdentifiers;
- (NSMenu*)addEditorPrefsMenu;
- (NSMenu*)addEditNotesMenu;
- (void)menusChanged;
- (void)_updateMenu:(NSMenu*)theMenu;
- (ExternalEditor*)defaultExternalEditor;
- (void)setDefaultEditor:(id)anEditor;
@end
