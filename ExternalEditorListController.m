//
//  ExternalEditorListController.m
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


#import "ExternalEditorListController.h"
#import "NoteObject.h"
#import "NotationController.h"
#import "NotationPrefs.h"
#import "NSBezierPath_NV.h"

static NSString *UserEEIdentifiersKey = @"UserEEIdentifiers";
static NSString *DefaultEEIdentifierKey = @"DefaultEEIdentifier";
NSString *ExternalEditorsChangedNotification = @"ExternalEditorsChanged";

@implementation ExternalEditor

- (id)initWithBundleID:(NSString*)aBundleIdentifier resolvedURL:(NSURL*)aURL {
	if ([self init]) {
		bundleIdentifier = [aBundleIdentifier retain];
		resolvedURL = [aURL retain];
		
		NSAssert(resolvedURL || bundleIdentifier, @"the bundle identifier and URL cannot both be nil");
		if (!bundleIdentifier) {
			if (!(bundleIdentifier = [[[NSBundle bundleWithPath:[aURL path]] bundleIdentifier] copy])) {
				NSLog(@"initWithBundleID:resolvedURL: URL does not seem to point to a valid bundle");
				return nil;
			}
		}
	}
	return self;
}

- (BOOL)canEditNoteDirectly:(NoteObject*)aNote {
	NSAssert(aNote != nil, @"aNote is nil");

	//for determining whether this potentially non-ODB-editor can open a non-plain-text file
	//process: does pathExtension key exist in knownPathExtensions dict?
	//if not, check this path extension w/ launch services
	//then add a corresponding YES/NO NSNumber value to the knownPathExtensions dict

	//but first, this editor can't handle any path if it's not actually installed
	if (![self isInstalled]) return NO;
	
	//and if this note isn't actually stored in a separate file, then obviously it can't be opened directly
	if ([[aNote delegate] currentNoteStorageFormat] == SingleDatabaseFormat) return NO;
	
	//and if aNote is in plaintext format and this editor is ODB-capable, then it should also be a general-purpose texteditor
	//conversely ODB editors should never be allowed to open non-plain-text documents; for some reason LSCanURLAcceptURL claims they can do that
	//one exception known: writeroom can edit rich-text documents
	if ([self isODBEditor] && ![bundleIdentifier hasPrefix:@"com.hogbaysoftware.WriteRoom"]) {
		return storageFormatOfNote(aNote) == PlainTextFormat;
	}
		
	if (!knownPathExtensions) knownPathExtensions = [NSMutableDictionary new];
	NSString *extension = [[filenameOfNote(aNote) pathExtension] lowercaseString];
	NSNumber *canHandleNumber = [knownPathExtensions objectForKey:extension];
	
	if (!canHandleNumber) {
		NSString *path = [aNote noteFilePath];
	
		Boolean canAccept = false;
		OSStatus err = LSCanURLAcceptURL((CFURLRef)[NSURL fileURLWithPath:path], (CFURLRef)[self resolvedURL], kLSRolesEditor, kLSAcceptAllowLoginUI, &canAccept);
		if (noErr != err) {
			NSLog(@"LSCanURLAcceptURL '%@' err: %d", path, err);
		}
		[knownPathExtensions setObject:[NSNumber numberWithBool:(BOOL)canAccept] forKey:extension];
		
		return (BOOL)canAccept;
	}
	
	return [canHandleNumber boolValue];
}

- (BOOL)canEditAllNotes:(NSArray*)notes {
	NSUInteger i = 0;
	for (i=0; i<[notes count]; i++) {
		if (![self isODBEditor] && ![self canEditNoteDirectly:[notes objectAtIndex:i]])
			return NO;
	}
	return YES;
}

- (NSImage*)iconImage {
	if (!iconImg) {
		FSRef appRef;
		if (CFURLGetFSRef((CFURLRef)[self resolvedURL], &appRef))
			iconImg = [[NSImage smallIconForFSRef:&appRef] retain];
	}
	return iconImg;
}

- (NSString*)displayName {
	if (!displayName) {
		LSCopyDisplayNameForURL((CFURLRef)[self resolvedURL], (CFStringRef*)&displayName);
	}
	return displayName;
}

- (NSURL*)resolvedURL {
	if (!resolvedURL && !installCheckFailed) {
		
		OSStatus err = LSFindApplicationForInfo(kLSUnknownCreator, (CFStringRef)bundleIdentifier, NULL, NULL, (CFURLRef*)&resolvedURL);
		
		if (kLSApplicationNotFoundErr == err) {
			installCheckFailed = YES;
		} else if (noErr != err) {
			NSLog(@"LSFindApplicationForInfo error for bundle identifier '%@': %d", bundleIdentifier, err);
		}
	}
	return resolvedURL;
}

- (BOOL)isInstalled {
	return [self resolvedURL] != nil;
}

- (BOOL)isODBEditor {
	return [[ExternalEditorListController ODBAppIdentifiers] containsObject:bundleIdentifier];
}

- (NSString*)bundleIdentifier {
	return bundleIdentifier;
}

- (NSString*)description {
	return [bundleIdentifier stringByAppendingFormat:@" (URL: %@)", resolvedURL];
}

- (NSUInteger)hash {
	return [bundleIdentifier hash];
}
- (BOOL)isEqual:(id)otherEntry {
	return [[otherEntry bundleIdentifier] isEqualToString:bundleIdentifier];
}
- (NSComparisonResult)compareDisplayName:(ExternalEditor *)otherEd {
    return [[self displayName] caseInsensitiveCompare:[otherEd displayName]];
}


- (void)dealloc {
	[knownPathExtensions release];
	[bundleIdentifier release];
	[displayName release];
	[resolvedURL release];
	[iconImg release];
	[super dealloc];
}


@end

@implementation ExternalEditorListController

static ExternalEditorListController* sharedInstance = nil;

+ (ExternalEditorListController*)sharedInstance {	
	if (sharedInstance == nil)
		sharedInstance = [[ExternalEditorListController alloc] initWithUserDefaults];
    return sharedInstance;
}

+ (id)allocWithZone:(NSZone *)zone {
	if (sharedInstance == nil) {
		sharedInstance = [super allocWithZone:zone];
		return sharedInstance;  // assignment and return on first allocation
	}
    return nil; // on subsequent allocation attempts return nil
}

- (id)initWithUserDefaults {
	if ([self init]) {
		//TextEdit is not an ODB editor, but can be used to open files directly
		[[NSUserDefaults standardUserDefaults] registerDefaults:
		 [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:@"com.apple.TextEdit"] forKey:UserEEIdentifiersKey]];
	
		[self _initDefaults];
	}
	return self;
}

- (id)init {
	if ([super init]) {
		
		userEditorList = [[NSMutableArray alloc] init];		
	}
	return self;
}

- (void)_initDefaults {
	NSArray *userIdentifiers = [[NSUserDefaults standardUserDefaults] arrayForKey:UserEEIdentifiersKey];
	
	NSUInteger i = 0;
	for (i=0; i<[userIdentifiers count]; i++) {
		ExternalEditor *ed = [[ExternalEditor alloc] initWithBundleID:[userIdentifiers objectAtIndex:i] resolvedURL:nil];
		[userEditorList addObject:ed];
		[ed release];
	}
	
	//initialize the default editor if one has not already been set or if the identifier was somehow lost from the list
	if (![self editorIsMember:[self defaultExternalEditor]] || ![[self defaultExternalEditor] isInstalled]) {
		if ([[self _installedODBEditors] count]) {
			[self setDefaultEditor:[[self _installedODBEditors] lastObject]];
		}
	}
}

- (NSArray*)_installedODBEditors {
	if (!_installedODBEditors) {
		_installedODBEditors = [[NSMutableArray alloc] initWithCapacity:5];
		
		NSArray *ODBApps = [[[self class] ODBAppIdentifiers] allObjects];
		NSUInteger i = 0;
		for (i=0; i<[ODBApps count]; i++) {
			ExternalEditor *ed = [[ExternalEditor alloc] initWithBundleID:[ODBApps objectAtIndex:i] resolvedURL:nil];
			if ([ed isInstalled]) {
				[_installedODBEditors addObject:ed];
			}
			[ed release];
		}
		[_installedODBEditors sortUsingSelector:@selector(compareDisplayName:)];
	}
	return _installedODBEditors;
}

+ (NSSet*)ODBAppIdentifiers {
	static NSSet *_ODBAppIdentifiers = nil;
	if (!_ODBAppIdentifiers) 
		_ODBAppIdentifiers = [[NSSet alloc] initWithObjects:
							  @"de.codingmonkeys.SubEthaEdit", @"com.barebones.bbedit", @"com.barebones.textwrangler", 
							  @"com.macromates.textmate", @"com.transtex.texeditplus", @"jp.co.artman21.JeditX", @"org.gnu.Aquamacs", 
							  @"org.smultron.Smultron", @"com.peterborgapps.Smultron", @"org.fraise.Fraise", @"com.aynimac.CotEditor", @"com.macrabbit.cssedit", 
							  @"com.talacia.Tag", @"org.skti.skEdit", @"com.cgerdes.ji", @"com.optima.PageSpinner", @"com.hogbaysoftware.WriteRoom", 
							  @"com.hogbaysoftware.WriteRoom.mac", @"org.vim.MacVim", @"com.forgedit.ForgEdit", @"com.tacosw.TacoHTMLEdit", @"com.macrabbit.espresso", nil];
	return _ODBAppIdentifiers;
}

- (void)addUserEditorFromDialog:(id)sender {
	
	//always send menuChanged notification because this class is the target of its menus, 
	//so the notification is the only way to maintain a consistent selected item in PrefsWindowController
	[self performSelector:@selector(menusChanged) withObject:nil afterDelay:0.0];
	
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    [openPanel setResolvesAliases:YES];
    [openPanel setAllowsMultipleSelection:NO];
    
    if ([openPanel runModalForDirectory:@"/Applications" file:nil types:[NSArray arrayWithObject:@"app"]] == NSOKButton) {
		if (![openPanel filename]) goto errorReturn;
		NSURL *appURL = [NSURL fileURLWithPath:[openPanel filename]];
		if (!appURL) goto errorReturn;
		
		ExternalEditor *ed = [[ExternalEditor alloc] initWithBundleID:nil resolvedURL:appURL];
		if (!ed) goto errorReturn;

		//check against lists of all known editors, installed or not
		if (![self editorIsMember:ed]) {
			[userEditorList addObject:ed];
			[[NSUserDefaults standardUserDefaults] setObject:[self userEditorIdentifiers] forKey:UserEEIdentifiersKey];
		}
		
		[self setDefaultEditor:ed];
    }
	return;
errorReturn:
	NSBeep();
	NSLog(@"Unable to add external editor");
}

- (void)resetUserEditors:(id)sender {
	[userEditorList removeAllObjects];
	
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:UserEEIdentifiersKey];
	
	[self _initDefaults];
	
	[self menusChanged];
}

- (NSArray*)userEditorIdentifiers {
	//for storing in nsuserdefaults
	//extract bundle identifiers
	
	NSMutableArray *array = [NSMutableArray arrayWithCapacity:[userEditorList count]];
	NSUInteger i = 0;
	for (i=0; i<[userEditorList count]; i++) {
		[array addObject:[[userEditorList objectAtIndex:i] bundleIdentifier]];
	}

	return array;
}


- (BOOL)editorIsMember:(ExternalEditor*)anEditor {
	//does the editor exist in any of the lists?
	return [userEditorList containsObject:anEditor] || [[ExternalEditorListController ODBAppIdentifiers] containsObject:[anEditor bundleIdentifier]];
}

- (NSMenu*)addEditorPrefsMenu {
	if (!editorPrefsMenus) editorPrefsMenus = [NSMutableSet new];
	NSMenu *aMenu = [[NSMenu alloc] initWithTitle:@"External Editors Menu"];
	[aMenu setAutoenablesItems:NO];
	[aMenu setDelegate:self];
	[editorPrefsMenus addObject:[aMenu autorelease]];
	[self _updateMenu:aMenu];
	return aMenu;
}

- (NSMenu*)addEditNotesMenu {
	if (!editNotesMenus) editNotesMenus = [NSMutableSet new];
	NSMenu *aMenu = [[NSMenu alloc] initWithTitle:@"Edit Note Menu"];
	[aMenu setAutoenablesItems:YES];
	[aMenu setDelegate:self];
	[editNotesMenus addObject:[aMenu autorelease]];
	[self _updateMenu:aMenu];
	return aMenu;
}

- (void)menusChanged {

	[editNotesMenus makeObjectsPerformSelector:@selector(_updateMenuForEEListController:) withObject:self];
	[editorPrefsMenus makeObjectsPerformSelector:@selector(_updateMenuForEEListController:) withObject:self];	
	[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:ExternalEditorsChangedNotification object:self]];
}

- (void)_updateMenu:(NSMenu*)theMenu {
	//for allowing the user to configure external editors in the preferences window

	if (IsSnowLeopardOrLater) {
		[theMenu performSelector:@selector(removeAllItems)];
	} else {
		while ([theMenu numberOfItems])
			[theMenu removeItemAtIndex:0];
	}
	
	BOOL isPrefsMenu = [editorPrefsMenus containsObject:theMenu];
	BOOL didAddItem = NO;
	NSMutableArray *editors = [NSMutableArray arrayWithArray:[self _installedODBEditors]];
	[editors addObjectsFromArray:[userEditorList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isInstalled == YES"]]];
	[editors sortUsingSelector:@selector(compareDisplayName:)];
	
	NSUInteger i = 0;
	for (i=0; i<[editors count]; i++) {
		ExternalEditor *ed = [editors objectAtIndex:i];
		
		//change action SEL based on whether this is coming from Notes menu or preferences window
		NSMenuItem *theMenuItem = isPrefsMenu ? 
			[[[NSMenuItem alloc] initWithTitle:[ed displayName] action:@selector(setDefaultEditor:) keyEquivalent:@""] autorelease] : 
			[[[NSMenuItem alloc] initWithTitle:[ed displayName] action:@selector(editNoteExternally:) keyEquivalent:@""] autorelease];
			
		if (!isPrefsMenu && [[self defaultExternalEditor] isEqual:ed]) {
			[theMenuItem setKeyEquivalent:@"E"];
			[theMenuItem setKeyEquivalentModifierMask: NSCommandKeyMask | NSShiftKeyMask];
		}
		//PrefsWindowController maintains default-editor selection by updating on ExternalEditorsChangedNotification
			
		[theMenuItem setTarget: isPrefsMenu ? self : [NSApp delegate]];
		
		[theMenuItem setRepresentedObject:ed];
//		
//		if ([ed iconImage])
//			[theMenuItem setImage:[ed iconImage]];
//		
		[theMenu addItem:theMenuItem];
		didAddItem = YES;
	}

	if (!didAddItem) {
		//disabled placeholder menu item; will probably not be displayed, but would be necessary for preferences list
		NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"(None)", @"description for no key combination") action:NULL keyEquivalent:@""] autorelease];
		[theMenuItem setEnabled:NO];
		[theMenu addItem:theMenuItem];
	}
	if ([userEditorList count] > 1 && isPrefsMenu) {
		//if the user added at least one editor (in addition to the default TextEdit item), then allow items to be reset to their default
		[theMenu addItem:[NSMenuItem separatorItem]];
		
		NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Reset", @"menu command to clear out custom external editors")
															  action:@selector(resetUserEditors:) keyEquivalent:@""] autorelease];
		[theMenuItem setTarget:self];
		[theMenu addItem:theMenuItem];
	}
	[theMenu addItem:[NSMenuItem separatorItem]];

	NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Other...", @"title of menu item for selecting a different notes folder")
														  action:@selector(addUserEditorFromDialog:) keyEquivalent:@""] autorelease];
	[theMenuItem setTarget:self];
	[theMenu addItem:theMenuItem];
}

- (ExternalEditor*)defaultExternalEditor {
	if (!defaultEditor) {
		NSString *defaultIdentifier = [[NSUserDefaults standardUserDefaults] stringForKey:DefaultEEIdentifierKey];
		if (defaultIdentifier)
			defaultEditor = [[ExternalEditor alloc] initWithBundleID:defaultIdentifier resolvedURL:nil];
	}
	return defaultEditor;
}

- (void)setDefaultEditor:(id)anEditor {
	if ((anEditor = ([anEditor isKindOfClass:[NSMenuItem class]] ? [anEditor representedObject] : anEditor))) {
		[defaultEditor release];
		defaultEditor = [anEditor retain];

		[[NSUserDefaults standardUserDefaults] setObject:[defaultEditor bundleIdentifier] forKey:DefaultEEIdentifierKey];
		
		[self menusChanged];
	}
}

@end


//this category exists because I want to use -makeObjectsPerformSelector: in -menusChanged

@interface NSMenu (ExternalEditorListMenu)
- (void)_updateMenuForEEListController:(ExternalEditorListController*)controller;
@end

@implementation NSMenu (ExternalEditorListMenu)
- (void)_updateMenuForEEListController:(ExternalEditorListController*)controller {
	[controller _updateMenu:self];
}
@end
