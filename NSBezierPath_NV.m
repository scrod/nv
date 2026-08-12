//
//  NSBezierPath_NV.m
//  Notation
//
//  Created by Zachary Schneirov on 1/14/11.

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

#import "NSBezierPath_NV.h"


@implementation NSBezierPath (NV)

+ (NSBezierPath *)bezierPathWithRoundRectInRect:(NSRect)aRect radius:(float)radius  {
	NSBezierPath* path = [NSBezierPath bezierPath];
	float smallestEdge = MIN(NSWidth(aRect), NSHeight(aRect));
	radius = MIN(radius, 0.5f * smallestEdge);
	NSRect rect = NSInsetRect(aRect, radius, radius);
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMinX(rect), NSMinY(rect)) radius:radius startAngle:180.0 endAngle:270.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(rect), NSMinY(rect)) radius:radius startAngle:270.0 endAngle:360.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(rect), NSMaxY(rect)) radius:radius startAngle:  0.0 endAngle: 90.0];
	[path appendBezierPathWithArcWithCenter:NSMakePoint(NSMinX(rect), NSMaxY(rect)) radius:radius startAngle: 90.0 endAngle:180.0];
	[path closePath];
	return path;
}

+ (NSBezierPath *)bezierPathWithLayoutManager:(NSLayoutManager*)layoutManager characterRange:(NSRange)charRange atPoint:(NSPoint)point {
	NSRange range = [layoutManager glyphRangeForCharacterRange:charRange actualCharacterRange:NULL];
	CGGlyph *cgGlyphs = NULL;
	if (range.length > 0) {
		cgGlyphs = (CGGlyph *)malloc(sizeof(CGGlyph) * range.length);
		if (cgGlyphs) {
			[layoutManager getGlyphsInRange:range glyphs:cgGlyphs properties:NULL characterIndexes:NULL bidiLevels:NULL];
		}
	}
	
	NSBezierPath *path = [NSBezierPath bezierPath];
	[path moveToPoint:point];
	if (cgGlyphs && range.length > 0) {
		[path appendBezierPathWithCGGlyphs:cgGlyphs count:range.length inFont:[[layoutManager textStorage] font]];
	}
	
	if (cgGlyphs) {
		free(cgGlyphs);
	}
	
	return path;
}


@end


@implementation NSImage (NV)

+ (void)nv_registerLegacySystemSymbolImages {
	static BOOL registered = NO;
	if (registered) return;
	registered = YES;

	typedef struct {
		NSString *legacyName;
		NSString *symbolName;
		NSString *accessibilityDescription;
		CGFloat pointSize;
		BOOL semibold;
	} NVLegacySymbol;

	static const NVLegacySymbol symbols[] = {
		{@"Add", @"plus", @"Add", 13.0, NO},
		{@"Add_Pressed", @"plus", @"Add", 13.0, NO},
		{@"Remove", @"minus", @"Remove", 13.0, NO},
		{@"Remove_Pressed", @"minus", @"Remove", 13.0, NO},
		{@"MakeDefault", @"checkmark", @"Make Default", 13.0, YES},
		{@"MakeDefault_Pressed", @"checkmark", @"Make Default", 13.0, YES},
		{@"PasswordAssistantButton", @"key.fill", @"Password Assistant", 13.0, NO},
		{@"PasswordAssistantButtonPressed", @"key.fill", @"Password Assistant", 13.0, NO},
		{@"PTKeyboardIcon", @"keyboard", @"Keyboard Shortcut", 20.0, NO},

		{@"General", @"gearshape", @"General", 24.0, NO},
		{@"Notes", @"note.text", @"Notes", 24.0, NO},
		{@"Editing", @"square.and.pencil", @"Editing", 24.0, NO},
		{@"Fonts & Colors", @"textformat", @"Fonts & Colors", 24.0, NO},

		{@"Clear", @"xmark", @"Clear Search", 10.0, YES},
		{@"ClearPressed", @"xmark", @"Clear Search", 10.0, YES},
		{@"SnapBack", @"arrow.uturn.backward", @"Return to All Notes", 11.0, YES},
		{@"SnapBackPressed", @"arrow.uturn.backward", @"Return to All Notes", 11.0, YES},
		{@"LinkBack", @"arrow.left", @"Back", 11.0, YES},
		{@"LinkBackPressed", @"arrow.left", @"Back", 11.0, YES},
		{@"Pencil", @"pencil", @"Editing Note", 13.0, NO},
		{@"Search", @"magnifyingglass", @"Search", 13.0, NO},

		{@"TBDownArrow", @"chevron.down", @"Show Sync Status", 10.0, YES},
		{@"TBDownArrowWhite", @"chevron.down", @"Show Sync Status", 10.0, YES},
		{@"TBSynchronizing", @"arrow.triangle.2.circlepath", @"Synchronizing", 10.0, YES},
		{@"TBSynchronizingWhite", @"arrow.triangle.2.circlepath", @"Synchronizing", 10.0, YES},
		{@"TBAlert", @"exclamationmark.triangle.fill", @"Sync Error", 10.0, NO},
		{@"TBAlertWhite", @"exclamationmark.triangle.fill", @"Sync Error", 10.0, NO},

		{@"TinyAlert", @"exclamationmark.triangle.fill", @"Warning", 13.0, NO},
		{@"statusValidated", @"checkmark.circle.fill", @"Validated", 12.0, NO},
		{@"statusInProgress", @"hourglass", @"In Progress", 12.0, NO},
		{@"statusError", @"xmark.circle.fill", @"Error", 12.0, NO},
	};

	for (NSUInteger i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++) {
		const NVLegacySymbol symbol = symbols[i];
		NSImage *image = [NSImage imageWithSystemSymbolName:symbol.symbolName
								 accessibilityDescription:NSLocalizedString(symbol.accessibilityDescription, nil)];
		image = [image imageWithSymbolConfiguration:
				 [NSImageSymbolConfiguration configurationWithPointSize:symbol.pointSize
												 weight:symbol.semibold ? NSFontWeightSemibold : NSFontWeightRegular]];
		NSCAssert(image != nil, @"Missing SF Symbol %@", symbol.symbolName);
		BOOL didRegister = [image setName:symbol.legacyName];
		NSCAssert(didRegister, @"Could not register image %@", symbol.legacyName);
	}
}

+ (NSImage*)smallIconForFileURL:(NSURL*)url {
	if (!url) return nil;
	NSImage *image = [[NSWorkspace sharedWorkspace] iconForFile:[url path]];
	[image setSize:NSMakeSize(16.0f, 16.0f)];
	return image;
}


@end
