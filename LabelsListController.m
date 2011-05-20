//
//  LabelsListController.m
//  Notation
//
//  Created by Zachary Schneirov on 1/10/06.

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


#import "LabelsListController.h"
#import "LabelObject.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NSBezierPath_NV.h"
#import "NSCollection_utils.h"


@implementation LabelsListController

- (id)init {
	if ([super init]) {
	    
	    allLabels = [[NSCountedSet alloc] init]; //authoritative
	    //for faster(?) filtering during search
	    filteredLabels = [[NSCountedSet alloc] init];
		
	    removeIndicies = NULL;
	}
	
	return self;
}

- (void)dealloc {
	
	[labelImages release];
	[allLabels release];
	[filteredLabels release];
	[super dealloc];
}

- (void)unfilterLabels {
    [filteredLabels setSet:allLabels];
    
    if ([filteredLabels count] > count) {
		count = [filteredLabels count];
		objects = (id*)realloc(objects, count * sizeof(id));
    }
    [filteredLabels getObjects:objects];
    
}

- (void)filterLabelSet:(NSSet*)labelSet {
	[filteredLabels minusSet:labelSet];
}

- (void)recomputeListFromFilteredSet {
    //we can ignore our objectsArray here as we never use it and just sort directly on our C-array
	[filteredLabels getObjects:objects];
	count = [filteredLabels count];
	
	//cfstringcompare here; strings always sorted alphabetically
	mergesort((void *)objects, (size_t)count, sizeof(id), (int (*)(const void *, const void *))compareLabel);
}

- (NSArray*)labelTitlesPrefixedByString:(NSString*)prefixString indexOfSelectedItem:(NSInteger *)anIndex minusWordSet:(NSSet*)antiSet {
	
	NSMutableArray *objs = [[[allLabels allObjects] mutableCopy] autorelease];
	NSMutableArray *titles = [NSMutableArray arrayWithCapacity:[allLabels count]];

	[objs sortUnstableUsingFunction:(NSInteger (*)(id *, id *))compareLabel];
	
	CFStringRef prefix = (CFStringRef)prefixString;
	NSUInteger i, titleLen, j = 0, shortestTitleLen = UINT_MAX;
	
	for (i=0; i<[objs count]; i++) {
		CFStringRef title = (CFStringRef)titleOfLabel((LabelObject*)[objs objectAtIndex:i]);
		
		if (CFStringFindWithOptions(title, prefix, CFRangeMake(0, CFStringGetLength(prefix)), kCFCompareAnchored | kCFCompareCaseInsensitive, NULL)) {
			
			if (![antiSet containsObject:(id)title]) {
				[titles addObject:(id)title];
				if (anIndex && (titleLen = CFStringGetLength(title)) < shortestTitleLen) {
					*anIndex = j;
					shortestTitleLen = titleLen;
				}
				j++;
			}
		}
	}
	return titles;
}

#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_5
static CGRect NSRectToCGRect(NSRect nsrect) {
    union _ {NSRect ns; CGRect cg;};
    return ((union _ *)&nsrect)->cg;
}
#endif

- (void)invalidateCachedLabelImages {
	//used when the list font size changes
	[labelImages removeAllObjects];
}
- (NSImage*)cachedLabelImageForWord:(NSString*)aWord highlighted:(BOOL)isHighlighted {
	if (!labelImages) labelImages = [[NSMutableDictionary alloc] init];
	
	NSString *imgKey = [[aWord lowercaseString] stringByAppendingFormat:@", %d", isHighlighted];
	NSImage *img = [labelImages objectForKey:imgKey];
	if (!img) {
		//generate the image and add it to labelImages under imgKey
		float tableFontSize = [[GlobalPrefs defaultPrefs] tableFontSize] - 1.0;
		NSDictionary *attrs = [NSDictionary dictionaryWithObject:[NSFont systemFontOfSize:tableFontSize] forKey:NSFontAttributeName];
		NSSize wordSize = [aWord sizeWithAttributes:attrs];
		NSRect wordRect = NSMakeRect(0, 0, roundf(wordSize.width + 4.0), roundf(tableFontSize * 1.3));
		
		//peter hosey's suggestion, rather than doing setWindingRule: and appendBezierPath: as before:
		//http://stackoverflow.com/questions/4742773/why-wont-helvetica-neue-bold-glyphs-draw-as-a-normal-subpath-in-nsbezierpath
		
		img = [[NSImage alloc] initWithSize:wordRect.size];
		[img lockFocus];

		CGContextRef context = (CGContextRef)([[NSGraphicsContext currentContext] graphicsPort]);
		CGContextBeginTransparencyLayer(context, NULL);

		CGContextClipToRect(context, NSRectToCGRect(wordRect));

		NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundRectInRect:wordRect radius:2.0f];
		[(isHighlighted ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite:0.55 alpha:1.0]) setFill];
		[backgroundPath fill];
		
		[[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOut];
		[aWord drawWithRect:(NSRect){{2.0, 3.0}, wordRect.size} options:NSStringDrawingUsesFontLeading attributes:attrs];
		
		CGContextEndTransparencyLayer(context);
		
		[img unlockFocus];
		
		[labelImages setObject:[img autorelease] forKey:imgKey];
	}
	return img;
}


//NotationController will probably want to filter these further if there is already a search in progress
- (NSSet*)notesAtFilteredIndex:(int)labelIndex {
    return [objects[labelIndex] noteSet];
}

//figure out which notes to display given some selected labels
- (NSSet*)notesAtFilteredIndexes:(NSIndexSet*)anIndexSet {
    NSUInteger i, numLabels = [anIndexSet count];
    NSUInteger *labelsBuffer = malloc(numLabels * sizeof(NSUInteger));
    
    NSRange range = NSMakeRange([anIndexSet firstIndex], ([anIndexSet lastIndex]-[anIndexSet firstIndex]) + 1);
    [anIndexSet getIndexes:labelsBuffer maxCount:numLabels inIndexRange:&range];
    
    NSMutableSet *notesOfLabels = [[NSMutableSet alloc] init];

    for (i=0; i<numLabels; i++) {
	int labelIndex = labelsBuffer[i];
	[notesOfLabels unionSet:[objects[labelIndex] noteSet]];
    }
    
    return [notesOfLabels autorelease];
}


/* these next two methods do NOT sync. object counts with the corresponding LabelObject(s) in allLabels;
   it's up to the sender to ensure that any given note is not added or removed from a label unnecessarily */

//called when deleting labels in a note
- (void)removeLabelSet:(NSSet*)labelSet fromNote:(NoteObject*)note {
    
    //labelSet in this case is probably not the prototype labelSet, so all that may be necessary is to call removeNote: on it
    //HOWEVER, don't know this for sure, assuming this API is to remain non-permeable
    
    [allLabels minusSet:labelSet];
    
	//could use this as an opportunity to remove counterparts in labelImages
    
    //we narrow down the set to make sure that we operate on the actual objects within it, and note the objects used as prototypes
    //these will be any labels that were shared by notes other than this one
    NSMutableSet *existingLabels = [allLabels setIntersectedWithSet:labelSet];
    [existingLabels makeObjectsPerformSelector:@selector(removeNote:) withObject:note];
}

//called for labels added to a note
- (void)addLabelSet:(NSSet*)labelSet toNote:(NoteObject*)note {
    
    [allLabels unionSet:labelSet];
    
    NSMutableSet *existingLabels = [allLabels setIntersectedWithSet:labelSet];
    [existingLabels makeObjectsPerformSelector:@selector(addNote:) withObject:note];
    [note replaceMatchingLabelSet:existingLabels]; //link back for the existing note, so that it knows about the other notes in this label
}


//useful for moving groups of notes from one label to another
- (void)removeLabelSet:(NSSet*)labelSet fromNoteSet:(NSSet*)notes {    
    [allLabels minusSet:labelSet];
    
	//could use this as an opportunity to remove counterparts in labelImages
    
    NSMutableSet *existingLabels = [allLabels setIntersectedWithSet:labelSet];
    [existingLabels makeObjectsPerformSelector:@selector(removeNoteSet:) withObject:notes];
}

- (void)addLabelSet:(NSSet*)labelSet toNoteSet:(NSSet*)notes {
    [allLabels unionSet:labelSet];
    
    NSMutableSet *existingLabels = [allLabels setIntersectedWithSet:labelSet];
    [existingLabels makeObjectsPerformSelector:@selector(addNoteSet:) withObject:notes];
    [notes makeObjectsPerformSelector:@selector(replaceMatchingLabelSet:) withObject:existingLabels];
}


@end
