//
//  LinkingEditor_Indentation.m
//  Notation
//

/*
 Modified code based on:
 
 Smultron version 3.1.2, 2007-07-16
 Written by Peter Borg, pgw3@mac.com
 Find the latest version at http://smultron.sourceforge.net
 
 Copyright 2004-2007 Peter Borg
 
 Licensed under the Apache License, Version 2.0 (the "License"); you may not
 use this file except in compliance with the License. You may obtain a copy
 of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 License for the specific language governing permissions and limitations
 under the License.
 */


#import "LinkingEditor_Indentation.h"
#import "GlobalPrefs.h"

@implementation LinkingEditor (Indentation)

- (IBAction)shiftLeftAction:(id)sender {	
	NSTextView *textView = self;
	NSString *completeString = [textView string];
	if ([completeString length] < 1) {
		return;
	}
	NSRange selectedRange;
	
	NSEnumerator *enumerator = [[self selectedRanges] objectEnumerator];
	
	id item;
    NSInteger sumOfAllCharactersRemoved = 0;
    NSInteger updatedLocation;
	NSMutableArray *updatedSelectionsArray = [[NSMutableArray alloc] init];
	while ((item = [enumerator nextObject])) {
		selectedRange = NSMakeRange([item rangeValue].location - sumOfAllCharactersRemoved, [item rangeValue].length);
            NSUInteger temporaryLocation = selectedRange.location;
            NSUInteger maxSelectedRange = NSMaxRange(selectedRange);
		int numberOfLines = 0;
            NSInteger locationOfFirstLine = [completeString lineRangeForRange:NSMakeRange(temporaryLocation, 0)].location;
		
		do {
			temporaryLocation = NSMaxRange([completeString lineRangeForRange:NSMakeRange(temporaryLocation, 0)]);
			numberOfLines++;
		} while (temporaryLocation < maxSelectedRange);
		
		temporaryLocation = selectedRange.location;
            NSInteger charIndex;
            NSInteger charactersRemoved = 0;
            NSInteger charactersRemovedInSelection = 0;
		NSRange rangeOfLine;
		unichar characterToTest;
		int numberOfSpacesPerTab = [[GlobalPrefs defaultPrefs] numberOfSpacesInTab];
		
		int numberOfSpacesToDeleteOnFirstLine = -1;
		for (charIndex = 0; charIndex < numberOfLines; charIndex++) {
			rangeOfLine = [completeString lineRangeForRange:NSMakeRange(temporaryLocation, 0)];
    if ([[GlobalPrefs defaultPrefs] softTabs]) {
                NSUInteger startOfLine = rangeOfLine.location;
				while (startOfLine < NSMaxRange(rangeOfLine) && [completeString characterAtIndex:startOfLine] == ' ' && rangeOfLine.length > 0) {
					startOfLine++;
				}
				int numberOfSpacesToDelete = numberOfSpacesPerTab;
				if (numberOfSpacesPerTab != 0) {
					numberOfSpacesToDelete = (startOfLine - rangeOfLine.location) % numberOfSpacesPerTab;
					if (numberOfSpacesToDelete == 0) {
						numberOfSpacesToDelete = numberOfSpacesPerTab;
					}
				}
				if (numberOfSpacesToDeleteOnFirstLine != -1) {
					numberOfSpacesToDeleteOnFirstLine = numberOfSpacesToDelete;
				}
				while (numberOfSpacesToDelete--) {
					characterToTest = [completeString characterAtIndex:rangeOfLine.location];
					if (characterToTest == ' ' || characterToTest == '\t') {
						if ([textView shouldChangeTextInRange:NSMakeRange(rangeOfLine.location, 1) replacementString:@""]) { // Do it this way to mark it as an Undo
							[textView replaceCharactersInRange:NSMakeRange(rangeOfLine.location, 1) withString:@""];
							[textView didChangeText];
						}
						charactersRemoved++;
						if (rangeOfLine.location >= selectedRange.location && rangeOfLine.location < maxSelectedRange) {
							charactersRemovedInSelection++;
						}
					}
				}
			} else {
				characterToTest = [completeString characterAtIndex:rangeOfLine.location];
				if ((characterToTest == ' ' || characterToTest == '\t') && rangeOfLine.length > 0) {
					if ([textView shouldChangeTextInRange:NSMakeRange(rangeOfLine.location, 1) replacementString:@""]) { // Do it this way to mark it as an Undo
						[textView replaceCharactersInRange:NSMakeRange(rangeOfLine.location, 1) withString:@""];
						[textView didChangeText];
					}			
					charactersRemoved++;
					if (rangeOfLine.location >= selectedRange.location && rangeOfLine.location < maxSelectedRange) {
						charactersRemovedInSelection++;
					}
				}
			}
			if (temporaryLocation < [[textView string] length]) {
				temporaryLocation = NSMaxRange([completeString lineRangeForRange:NSMakeRange(temporaryLocation, 0)]);
			}
		}
		
            if (selectedRange.length > 0 && charactersRemoved > 0) {
                NSInteger selectedRangeLocation = selectedRange.location; // Use NSInteger for 64-bit safety
                NSInteger charactersToCountBackwards = 1;
			if (numberOfSpacesToDeleteOnFirstLine != -1) {
				charactersToCountBackwards = numberOfSpacesToDeleteOnFirstLine;
			}
			if (selectedRangeLocation - charactersToCountBackwards <= locationOfFirstLine) {
				updatedLocation = locationOfFirstLine;
			} else {
				updatedLocation = selectedRangeLocation - charactersToCountBackwards;
			}
			[updatedSelectionsArray addObject:[NSValue valueWithRange:NSMakeRange(updatedLocation, selectedRange.length - charactersRemovedInSelection)]];
		}
		sumOfAllCharactersRemoved = sumOfAllCharactersRemoved + charactersRemoved;
	}
	
	if (sumOfAllCharactersRemoved == 0) {
		NSBeep();
	}
	if ([updatedSelectionsArray count] > 0) {
		[textView setSelectedRanges:updatedSelectionsArray];
	}
	[updatedSelectionsArray release];
}

- (IBAction)shiftRightAction:(id)sender {
	NSTextView *textView = self;
	NSString *completeString = [textView string];
	if ([completeString length] < 1) {
		return;
	}
	NSRange selectedRange;
	
	NSMutableString *replacementString;
	if ([[GlobalPrefs defaultPrefs] softTabs]) {
		replacementString = [[NSMutableString alloc] init];
        int numberOfSpacesPerTab = [[GlobalPrefs defaultPrefs] numberOfSpacesInTab];
		
        NSUInteger locationOnLine = [textView selectedRange].location - [[textView string] lineRangeForRange:NSMakeRange([textView selectedRange].location, 0)].location;
        if (numberOfSpacesPerTab != 0) {
            int numberOfSpacesLess = (int)(locationOnLine % (NSUInteger)numberOfSpacesPerTab);
            numberOfSpacesPerTab = numberOfSpacesPerTab - numberOfSpacesLess;
        }
		
		while (numberOfSpacesPerTab--) {
			[replacementString appendString:@" "];
		}
	} else {
		replacementString = [[NSMutableString alloc] initWithString:@"\t"];
	}
    NSInteger replacementStringLength = [replacementString length];
	
	NSEnumerator *enumerator = [[self selectedRanges] objectEnumerator];
	
	id item;
    NSInteger sumOfAllCharactersInserted = 0;
    NSInteger updatedLocation;
	NSMutableArray *updatedSelectionsArray = [[NSMutableArray alloc] init];
	while ((item = [enumerator nextObject])) {
		selectedRange = NSMakeRange([item rangeValue].location + sumOfAllCharactersInserted, [item rangeValue].length);
        NSUInteger temporaryLocation = selectedRange.location;
        NSUInteger maxSelectedRange = NSMaxRange(selectedRange);
		int numberOfLines = 0;
        NSInteger locationOfFirstLine = [completeString lineRangeForRange:NSMakeRange(temporaryLocation, 0)].location;
		
		do {
			temporaryLocation = NSMaxRange([completeString lineRangeForRange:NSMakeRange(temporaryLocation, 0)]);
			numberOfLines++;
		} while (temporaryLocation < maxSelectedRange);
		
		temporaryLocation = selectedRange.location;
        NSInteger charIndex;
        NSInteger charactersInserted = 0;
        NSInteger charactersInsertedInSelection = 0;
		NSRange rangeOfLine;
		for (charIndex = 0; charIndex < numberOfLines; charIndex++) {
			rangeOfLine = [completeString lineRangeForRange:NSMakeRange(temporaryLocation, 0)];
			if ([textView shouldChangeTextInRange:NSMakeRange(rangeOfLine.location, 0) replacementString:replacementString]) { // Do it this way to mark it as an Undo
				[textView replaceCharactersInRange:NSMakeRange(rangeOfLine.location, 0) withString:replacementString];
				[textView didChangeText];
			}			
			charactersInserted = charactersInserted + replacementStringLength;
			if (rangeOfLine.location >= selectedRange.location && rangeOfLine.location < maxSelectedRange + charactersInserted) {
				charactersInsertedInSelection = charactersInsertedInSelection + replacementStringLength;
			}
			if (temporaryLocation < [[textView string] length]) {
				temporaryLocation = NSMaxRange([completeString lineRangeForRange:NSMakeRange(temporaryLocation, 0)]);
			}	
		}
		
		if (selectedRange.length > 0) {
			if (selectedRange.location + replacementStringLength >= [[textView string] length]) {
				updatedLocation = locationOfFirstLine;
			} else {
				updatedLocation = selectedRange.location;
			}
			[updatedSelectionsArray addObject:[NSValue valueWithRange:NSMakeRange(updatedLocation, selectedRange.length + charactersInsertedInSelection)]];
		}
		sumOfAllCharactersInserted = sumOfAllCharactersInserted + charactersInserted;
		
	}
	
	if ([updatedSelectionsArray count] > 0) {
		[textView setSelectedRanges:updatedSelectionsArray];
	}
	[replacementString release];
	[updatedSelectionsArray release];
}


@end
