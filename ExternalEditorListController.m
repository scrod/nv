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
#import "AppController.h"
#import "NoteObject.h"
#import "NotationController.h"
#import "NotationPrefs.h"
#import "NSBezierPath_NV.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *UserEEIdentifiersKey = @"UserEEIdentifiers";
static NSString *DefaultEEIdentifierKey = @"DefaultEEIdentifier";
NSString *ExternalEditorsChangedNotification = @"ExternalEditorsChanged";

@interface NSMenu (ExternalEditorListMenu)
- (void)_updateMenuForEEListController:(ExternalEditorListController*)controller;
@end

@interface ExternalEditorListController ()
- (NSArray*)_editorsForNotes:(NSArray*)notes;
@end


@implementation ExternalEditor

@synthesize bundleIdentifier;

- (id)initWithBundleID:(NSString*)aBundleIdentifier resolvedURL:(NSURL*)aURL {
	self = [self init];
	if (self) {
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

	//for determining whether this external editor can open a non-plain-text file
	//process: does pathExtension key exist in knownPathExtensions dict?
	//if not, check this path extension w/ launch services
	//then add a corresponding YES/NO NSNumber value to the knownPathExtensions dict

	//but first, this editor can't handle any path if it's not actually installed
	if (![self isInstalled]) return NO;

	//and if this note isn't actually stored in a separate file, then obviously it can't be opened directly
	if ([[aNote delegate] currentNoteStorageFormat] == SingleDatabaseFormat) return NO;

	if (!knownPathExtensions) knownPathExtensions = [NSMutableDictionary new];
	NSString *extension = [[filenameOfNote(aNote) pathExtension] lowercaseString];
	NSNumber *canHandleNumber = [knownPathExtensions objectForKey:extension];

	if (!canHandleNumber) {
		NSURL *noteURL = [aNote absoluteUNIXPath];

		Boolean canAccept = false;
		OSStatus err = noteURL ? LSCanURLAcceptURL((CFURLRef)noteURL, (CFURLRef)[self resolvedURL], kLSRolesEditor, kLSAcceptAllowLoginUI, &canAccept) : fnfErr;
		if (noErr != err) {
			NSLog(@"LSCanURLAcceptURL '%@' err: %d", noteURL, err);
		}
		[knownPathExtensions setObject:[NSNumber numberWithBool:(BOOL)canAccept] forKey:extension];

		return (BOOL)canAccept;
	}

	return [canHandleNumber boolValue];
}

- (BOOL)canEditAllNotes:(NSArray*)notes {
	for (NoteObject *note in notes) {
		if ([[note delegate] currentNoteStorageFormat] != SingleDatabaseFormat &&
			![self canEditNoteDirectly:note])
			return NO;
	}
	return YES;
}

- (NSImage*)iconImage {
	if (!iconImg) {
		NSURL *appURL = [self resolvedURL];
		if (appURL) {
			NSImage *workspaceIcon = [[[NSWorkspace sharedWorkspace] iconForFile:[appURL path]] copy];
			if (workspaceIcon) {
				[workspaceIcon setSize:NSMakeSize(16.0f, 16.0f)];
				iconImg = workspaceIcon;
			}
		}
	}
	return iconImg;
}

- (NSString*)displayName {
	if (!displayName) {
		NSURL *appURL = [self resolvedURL];
		if (appURL) {
			NSString *localizedName = nil;
			NSError *nameError = nil;
			if (![appURL getResourceValue:&localizedName forKey:NSURLLocalizedNameKey error:&nameError] || ![localizedName length]) {
				localizedName = [[NSFileManager defaultManager] displayNameAtPath:[appURL path]];
			}
			if (![localizedName length]) {
				localizedName = bundleIdentifier;
			}
			displayName = [localizedName copy];
		} else {
			displayName = [bundleIdentifier copy];
		}
	}
	return displayName;
}

- (NSURL*)resolvedURL {
	if (!resolvedURL && !installCheckFailed) {
		NSURL *appURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleIdentifier];
		if (appURL) {
			resolvedURL = [appURL retain];
		} else {
			installCheckFailed = YES;
			NSLog(@"Unable to locate application for bundle identifier '%@'", bundleIdentifier);
		}
	}
	return resolvedURL;
}

- (BOOL)isInstalled {
	return [self resolvedURL] != nil;
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
	self = [self init];
	if (self) {
		//TextEdit is always present
		[[NSUserDefaults standardUserDefaults] registerDefaults:
		 [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:@"com.apple.TextEdit"] forKey:UserEEIdentifiersKey]];

		[self _initDefaults];
	}
	return self;
}

- (id)init {
	self = [super init];
	if (self) {

		userEditorList = [[NSMutableArray alloc] init];
	}
	return self;
}

- (void)_initDefaults {
	NSArray *userIdentifiers = [[NSUserDefaults standardUserDefaults] arrayForKey:UserEEIdentifiersKey];

	for (NSString *identifier in userIdentifiers) {
		ExternalEditor *ed = [[ExternalEditor alloc] initWithBundleID:identifier resolvedURL:nil];
		[userEditorList addObject:ed];
		[ed release];
	}

	//initialize the default editor if one has not already been set or if the identifier was somehow lost from the list
	if (![[self defaultExternalEditor] isInstalled]) {
		ExternalEditor *textEdit = [[[ExternalEditor alloc]
			initWithBundleID:@"com.apple.TextEdit" resolvedURL:nil] autorelease];
		if ([textEdit isInstalled]) [self setDefaultEditor:textEdit];
	}
}

- (void)addUserEditorFromDialog:(id)sender {

	//always send menuChanged notification because this class is the target of its menus,
	//so the notification is the only way to maintain a consistent selected item in PrefsWindowController
	[self performSelector:@selector(menusChanged) withObject:nil afterDelay:0.0];

	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    [openPanel setResolvesAliases:YES];
    [openPanel setAllowsMultipleSelection:NO];
    [openPanel setDirectoryURL:[NSURL fileURLWithPath:@"/Applications"]];
    [openPanel setAllowedFileTypes:@[@"app"]];

    if ([openPanel runModal] == NSModalResponseOK) {
		if (![[openPanel URL] path]) goto errorReturn;
		NSURL *appURL = [openPanel URL];
		if (!appURL) goto errorReturn;

		ExternalEditor *ed = [[ExternalEditor alloc] initWithBundleID:nil resolvedURL:appURL];
		if (!ed) goto errorReturn;

		//check against lists of all known editors, installed or not
		if (![self editorIsMember:ed]) {
			[userEditorList addObject:ed];
			[[NSUserDefaults standardUserDefaults] setObject:[self userEditorIdentifiers] forKey:UserEEIdentifiersKey];
		}

		[self setDefaultEditor:ed];
		[ed release];
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
	for (ExternalEditor *editor in userEditorList) {
		[array addObject:editor.bundleIdentifier];
	}

	return array;
}


- (BOOL)editorIsMember:(ExternalEditor*)anEditor {
	return [userEditorList containsObject:anEditor];
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

- (NSArray*)_applicationURLsForNote:(NoteObject*)note {
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	if (note && [[note delegate] currentNoteStorageFormat] != SingleDatabaseFormat) {
		NSURL *URL = [note absoluteUNIXPath];
		if (!URL) return [NSArray array];
		if (@available(macOS 12.0, *))
			return [workspace URLsForApplicationsToOpenURL:URL];
		CFArrayRef URLs = LSCopyApplicationURLsForURL((CFURLRef)URL, kLSRolesEditor);
		return [(NSArray*)URLs autorelease];
	}
	if (@available(macOS 12.0, *)) {
		NSMutableOrderedSet *URLs = [NSMutableOrderedSet orderedSet];
		NSArray *types = note ? @[ UTTypePlainText ] : @[ UTTypePlainText, UTTypeRTF, UTTypeHTML ];
		for (UTType *type in types)
			[URLs addObjectsFromArray:[workspace URLsForApplicationsToOpenContentType:type]];
		return [URLs array];
	}
	NSMutableSet *identifiers = [NSMutableSet set];
	NSArray *types = note ? @[ (NSString*)kUTTypePlainText ] :
		@[ (NSString*)kUTTypePlainText, (NSString*)kUTTypeRTF, (NSString*)kUTTypeHTML ];
	for (NSString *type in types) {
		CFArrayRef handlers = LSCopyAllRoleHandlersForContentType((CFStringRef)type, kLSRolesEditor);
		if (handlers) {
			[identifiers addObjectsFromArray:(NSArray*)handlers];
			CFRelease(handlers);
		}
	}
	NSMutableArray *URLs = [NSMutableArray array];
	for (NSString *identifier in identifiers) {
		NSURL *URL = [workspace URLForApplicationWithBundleIdentifier:identifier];
		if (URL) [URLs addObject:URL];
	}
	return URLs;
}

- (NSArray*)_editorsForNotes:(NSArray*)notes {
	NSArray *probeNotes = [notes count] ? notes : [NSArray arrayWithObject:[NSNull null]];
	NSMutableDictionary *common = nil;
	for (id value in probeNotes) {
		NoteObject *note = value == [NSNull null] ? nil : value;
		NSMutableDictionary *applications = [NSMutableDictionary dictionary];
		for (NSURL *URL in [self _applicationURLsForNote:note]) {
			NSString *identifier = [[NSBundle bundleWithURL:URL] bundleIdentifier];
			if (![identifier length] || [identifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]])
				continue;
			ExternalEditor *editor = [[[ExternalEditor alloc]
				initWithBundleID:identifier resolvedURL:URL] autorelease];
			[applications setObject:editor forKey:identifier];
		}
		if (!common) common = [applications mutableCopy];
		else for (NSString *identifier in [[[common allKeys] copy] autorelease]) {
			if (![applications objectForKey:identifier]) [common removeObjectForKey:identifier];
		}
	}
	if (!common) common = [[NSMutableDictionary alloc] init];
	for (ExternalEditor *editor in userEditorList)
		if ([editor isInstalled] && (![notes count] || [editor canEditAllNotes:notes]))
			[common setObject:editor forKey:[editor bundleIdentifier]];
	NSArray *result = [[common allValues] sortedArrayUsingSelector:@selector(compareDisplayName:)];
	[common release];
	return result;
}

- (void)_updateMenu:(NSMenu*)theMenu {
	//for allowing the user to configure external editors in the preferences window

	[theMenu removeAllItems];

	BOOL isPrefsMenu = [editorPrefsMenus containsObject:theMenu];
	BOOL didAddItem = NO;
	NSArray *selectedNotes = nil;
	if (!isPrefsMenu && [[NSApp delegate] respondsToSelector:@selector(selectedNotes)])
		selectedNotes = [(AppController*)[NSApp delegate] selectedNotes];
	NSArray *editors = [self _editorsForNotes:selectedNotes];

	for (ExternalEditor *ed in editors) {

		//change action SEL based on whether this is coming from Notes menu or preferences window
		NSMenuItem *theMenuItem = isPrefsMenu ?
			[[[NSMenuItem alloc] initWithTitle:[ed displayName] action:@selector(setDefaultEditor:) keyEquivalent:@""] autorelease] :
			[[[NSMenuItem alloc] initWithTitle:[ed displayName] action:@selector(editNoteExternally:) keyEquivalent:@""] autorelease];

		if (!isPrefsMenu && [[self defaultExternalEditor] isEqual:ed]) {
			[theMenuItem setKeyEquivalent:@"E"];
			[theMenuItem setKeyEquivalentModifierMask: NSEventModifierFlagCommand | NSEventModifierFlagShift];
		}
		//PrefsWindowController maintains default-editor selection by updating on ExternalEditorsChangedNotification

		[theMenuItem setTarget: isPrefsMenu ? (id)self : (id)[NSApp delegate]];

		[theMenuItem setRepresentedObject:ed];

		if ([ed iconImage])
			[theMenuItem setImage:[ed iconImage]];

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

- (void)menuNeedsUpdate:(NSMenu*)menu {
	[self _updateMenu:menu];
	if ([editorPrefsMenus containsObject:menu])
		[[NSNotificationCenter defaultCenter] postNotificationName:ExternalEditorsChangedNotification object:self];
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

@implementation NSMenu (ExternalEditorListMenu)
- (void)_updateMenuForEEListController:(ExternalEditorListController*)controller {
	[controller _updateMenu:self];
}
@end
