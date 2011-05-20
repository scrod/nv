//
//  AppController_Importing.m
//  Notation
//
//  Created by Zachary Schneirov on 1/14/11.

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


#import "AppController_Importing.h"
#import "NotationController.h"
#import "NotationFileManager.h"
#import "BookmarksController.h"
#import "DualField.h"
#import "SyncSessionController.h"
#import "NotationSyncServiceManager.h"
#import "NotationDirectoryManager.h"
#import "AlienNoteImporter.h"
#import "NSString_NV.h"
#import <WebKit/WebArchive.h>
#import "GlobalPrefs.h"
#import "NSData_transformations.h"
#import "AttributedPlainText.h"
#import "NSCollection_utils.h"
#import "NoteObject.h"
#import "NotationPrefs.h"

@implementation AppController (Importing)

- (BOOL)addNotesFromPasteboard:(NSPasteboard*)pasteboard {
	
	NSArray *types = [pasteboard types];
	NSMutableAttributedString *newString = nil;
	NSData *data = nil;
	BOOL pbHasPlainText = [types containsObject:NSStringPboardType];
	
	if ([types containsObject:NSFilenamesPboardType]) {
		NSArray *files = [pasteboard propertyListForType:NSFilenamesPboardType];
		if ([files isKindOfClass:[NSArray class]]) {
			if ([notationController openFiles:files]) return YES;
		}
	}
	
	NSString *sourceIdentifierString = nil;
	
	//webkit URL!
	if ([types containsObject:WebArchivePboardType]) {
		sourceIdentifierString = [[pasteboard dataForType:WebArchivePboardType] pathURLFromWebArchive];
		//gecko URL!
	} else if ([types containsObject:[NSString customPasteboardTypeOfCode:0x4D5A0003]]) {
		//lazilly use syntheticTitle to get first line, even though that's not how our API is documented
		sourceIdentifierString = [[pasteboard stringForType:[NSString customPasteboardTypeOfCode:0x4D5A0003]] syntheticTitleAndTrimmedBody:NULL];
		unichar nullChar = 0x0;
		sourceIdentifierString = [sourceIdentifierString stringByReplacingOccurrencesOfString:
								  [NSString stringWithCharacters:&nullChar length:1] withString:@""];
	}
	
	if ([types containsObject:NSURLPboardType] || (pbHasPlainText && [[pasteboard stringForType:NSStringPboardType] superficiallyResemblesAnHTTPURL])) {
		NSURL *url = [NSURL URLFromPasteboard:pasteboard];
		if (!url) url = [NSURL URLWithString:[pasteboard stringForType:NSStringPboardType]];
		
		NSString *potentialURLString = pbHasPlainText ? [pasteboard stringForType:NSStringPboardType] : nil;
		if (potentialURLString && [[url absoluteString] isEqualToString:potentialURLString]) {
			//only begin downloading if we know that there's no other useful string data
			//because we've already checked NSFilenamesPboardType
			
			if ([[url scheme] caseInsensitiveCompare:@"http"] == NSOrderedSame || 
				[[url scheme] caseInsensitiveCompare:@"https"] == NSOrderedSame ||
				[[url scheme] caseInsensitiveCompare:@"ftp"] == NSOrderedSame) {
				NSString *linkTitleType = [NSString customPasteboardTypeOfCode:0x75726C6E];
				NSString *linkTitle = [types containsObject:linkTitleType] ? [[pasteboard stringForType:linkTitleType] syntheticTitleAndTrimmedBody:NULL] : nil;
				if (!linkTitle) {
					//try urld instead of urln
					linkTitleType = [NSString customPasteboardTypeOfCode:0x75726C64];
					linkTitle = [types containsObject:linkTitleType] ? [[pasteboard stringForType:linkTitleType] syntheticTitleAndTrimmedBody:NULL] : nil;
				}
				[[[[AlienNoteImporter alloc] init] autorelease] importURLInBackground:url linkTitle:linkTitle receptionDelegate:self];
				return YES;
			}
		}		
	}
	
	//safari on 10.5 does not seem to provide a plain-text equivalent, so we must be able to dumb-down RTF data as well
	//should fall-back to plain text if 1) user doesn't want styles and 2) plain text is actually available
	BOOL shallUsePlainTextFallback = pbHasPlainText && ![prefsController pastePreservesStyle];
	BOOL hasRTFData = NO;
	
	if ([types containsObject:NVPTFPboardType]) {
		if ((data = [pasteboard dataForType:NVPTFPboardType]))
			newString = [[NSMutableAttributedString alloc] initWithRTF:data documentAttributes:NULL];
		
	} else if ([types containsObject:NSRTFPboardType] && !shallUsePlainTextFallback) {
		if ((data = [pasteboard dataForType:NSRTFPboardType]))
			newString = [[NSMutableAttributedString alloc] initWithRTF:data documentAttributes:NULL];
		hasRTFData = YES;
	} else if ([types containsObject:NSRTFDPboardType] && !shallUsePlainTextFallback) {
		if ((data = [pasteboard dataForType:NSRTFDPboardType]))
			newString = [[NSMutableAttributedString alloc] initWithRTFD:data documentAttributes:NULL];
		hasRTFData = YES;
	} else if ([types containsObject:WebArchivePboardType] && !shallUsePlainTextFallback) {
		if ((data = [pasteboard dataForType:WebArchivePboardType])) {
			//set a timeout because -[NSHTMLReader _loadUsingWebKit] can sometimes hang
			newString = [[NSMutableAttributedString alloc] initWithData:data options:[NSDictionary optionsDictionaryWithTimeout:10.0] 
													 documentAttributes:NULL error:NULL];
		}
		hasRTFData = YES;
		
	} else if ([types containsObject:NSHTMLPboardType] && !shallUsePlainTextFallback) {
		if ((data = [pasteboard dataForType:NSHTMLPboardType]))
			newString = [[NSMutableAttributedString alloc] initWithHTML:data documentAttributes:NULL];
		hasRTFData = YES;
	} else if (pbHasPlainText) {
		
		NSString *pboardString = [pasteboard stringForType:NSStringPboardType];
		if (pboardString) newString = [[NSMutableAttributedString alloc] initWithString:pboardString];
	}
	
	[newString autorelease];
	if ([newString length] > 0) {
		[newString removeAttachments];
		
		if (hasRTFData && ![prefsController pastePreservesStyle]) //fallback scenario
			newString = [[[NSMutableAttributedString alloc] initWithString:[newString string]] autorelease];
		
		NSUInteger bodyLoc = 0, prefixedSourceLength = 0;
		NSString *noteTitle = [[newString string] syntheticTitleAndSeparatorWithContext:NULL bodyLoc:&bodyLoc maxTitleLen:36];
		if ([sourceIdentifierString length] > 0) {
			//add the URL or wherever it was that this piece of text came from
			prefixedSourceLength = [[newString prefixWithSourceString:sourceIdentifierString] length];
		}
		[newString santizeForeignStylesForImporting];
		
		NoteObject *note = [[[NoteObject alloc] initWithNoteBody:newString title:noteTitle delegate:notationController
														  format:[notationController currentNoteStorageFormat] labels:nil] autorelease];
		if (bodyLoc > 0 && [newString length] >= bodyLoc + prefixedSourceLength) [note setSelectedRange:NSMakeRange(prefixedSourceLength, bodyLoc)];
		[notationController addNewNote:note];
		
		return note != nil;
	}
	
	return NO;
}

- (BOOL)interpretNVURL:(NSURL*)aURL {
	// currently supported:
	// hostname -> command
	// first level -> search term / title
	// second level -> sync keys as parameters
	// example: nv://find/url%20test/?SN=agtzaW1wbGUtbm90ZXINCxIETm90ZRiY-dEFDA&NV=5WJ0eP3YRaCjyQn%2F8p62iQ%3D%3D
	
	NSUInteger j, i = 0;
	
	if ([[aURL host] isEqualToString:@"find"]) {
		//dispatch searchForString: and revealNote:options: as appropriate
		
		//add currentNote to the snapback button back-stack
		if (currentNote) {
			[field pushFollowedLink:[[[NoteBookmark alloc] initWithNoteObject:currentNote searchString:[self fieldSearchString]] autorelease]];
		}
		
		NSString *terms = [aURL path];
		[self searchForString:([terms length] && [terms characterAtIndex:0] == '/') ? [terms substringFromIndex:1] : terms];
		
		NSArray *params = [[aURL query] componentsSeparatedByString:@"&"];
		NSArray *svcs = [[SyncSessionController class] allServiceNames];
		NoteObject *foundNote = nil;
		
		for (i=0; i<[params count]; i++) {
			NSString *idStr = [params objectAtIndex:i];
			
			if ([idStr hasPrefix:@"NV="] && [idStr length] > 3) {
				NSData *uuidData = [[[idStr substringFromIndex:3] stringByReplacingPercentEscapes] decodeBase64WithNewlines:NO];
				if ((foundNote = [notationController noteForUUIDBytes:(CFUUIDBytes*)[uuidData bytes]]))
					goto handleFound;
			}
			
			for (j=0; j<[svcs count]; j++) {
				NSString *serviceName = [svcs objectAtIndex:j];
				if ([idStr hasPrefix:[NSString stringWithFormat:@"%@=", serviceName]] && [idStr length] > [serviceName length] + 1) {
					//lookup note with identical key for this service
					NSString *key = [[idStr substringFromIndex:[serviceName length] + 1] stringByReplacingPercentEscapes];
					if ((foundNote = [notationController noteForKey:key ofServiceClass:[[SyncSessionController allServiceClasses] objectAtIndex:j]]))
						goto handleFound;
				}
			}
		}
	handleFound:
		//if this search had initiated a clearing of the history, then make sure it doesn't happen
		[NSObject cancelPreviousPerformRequestsWithTarget:field selector:@selector(clearFollowedLinks) object:nil];
		
		if (foundNote) [self revealNote:foundNote options:NVOrderFrontWindow];
		return YES;
		
	} else if ([[aURL host] isEqualToString:@"make"]) {
		
		NSArray *params = [[aURL query] componentsSeparatedByString:@"&"];
		
		//parameters: "title" and one of the following for the body: "txt", "html" (maybe "md" for markdown in the future)
		//if title is missing, add the body via -[addNotesFromPasteboard:]
		NSString *title = nil, *txtBody = nil, *htmlBody = nil, *tags = nil, *urlTxt = nil;
		for (i=0; i<[params count]; i++) {
			NSString *compStr = [params objectAtIndex:i];
			if ([compStr hasPrefix:@"title="] && [compStr length] > 6) {
				title = [[compStr substringFromIndex:6] stringByReplacingPercentEscapes];
			} else if ([compStr hasPrefix:@"txt="] && [compStr length] > 4) {
				txtBody = [[compStr substringFromIndex:4] stringByReplacingPercentEscapes];
			} else if ([compStr hasPrefix:@"html="] && [compStr length] > 5) {
				htmlBody = [[compStr substringFromIndex:5] stringByReplacingPercentEscapes];
			} else if ([compStr hasPrefix:@"tags="] && [compStr length] > 5) {
				tags = [[compStr substringFromIndex:5] stringByReplacingPercentEscapes];
			}else if ([compStr hasPrefix:@"url="] && [compStr length] > 4) {
				urlTxt = [[compStr substringFromIndex:4] stringByReplacingPercentEscapes];
                txtBody = nil;
                htmlBody = nil;
			}
		}
        if (urlTxt) {
            //  NSPasteboard *pboard = [NSPasteboard pasteboardWithUniqueName];
            NSURL *theURL = [NSURL URLWithString:urlTxt];
            //	NSData *data = [urlTxt dataUsingEncoding:NSUTF8StringEncoding];
            if (theURL) {                
                // [pboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
                //[pboard setData:data forType:NSStringPboardType];
                NSString *linkTitle = nil;
                if (title) {
                    linkTitle = title;
                }
                [[[[AlienNoteImporter alloc] init] autorelease] importURLInBackground:theURL linkTitle:linkTitle receptionDelegate:self];
            }
            return;
        }else{
            if (title && (txtBody || htmlBody)) {
                NSMutableAttributedString *attributedContents = nil;
                
                if (htmlBody) {
                    attributedContents = [[NSMutableAttributedString alloc] initWithHTML:[htmlBody dataUsingEncoding:NSUTF8StringEncoding] 
                                                                                 options:[NSDictionary optionsDictionaryWithTimeout:10.0] documentAttributes:NULL];
                } else {
                    attributedContents = [[NSMutableAttributedString alloc] initWithString:txtBody attributes:[prefsController noteBodyAttributes]];
                }
                [attributedContents removeAttachments];
                [attributedContents santizeForeignStylesForImporting];
                
                NoteObject *note = [[[NoteObject alloc] initWithNoteBody:[attributedContents autorelease] title:title delegate:notationController
                                                                  format:[notationController currentNoteStorageFormat] labels:tags] autorelease];
                [notationController addNewNote:note];
                return YES;
            } else if (txtBody || htmlBody) {
                NSPasteboard *pboard = [NSPasteboard pasteboardWithUniqueName];
                NSData *data = [htmlBody dataUsingEncoding:NSUTF8StringEncoding];
                [pboard declareTypes:[NSArray arrayWithObject: data ? NSHTMLPboardType : NSStringPboardType] owner:nil];
                if (data) {
                    [pboard setData:data forType:NSHTMLPboardType];
                } else if (txtBody) {
                    [pboard setString:txtBody forType:NSStringPboardType];
                } else {
                    NSLog(@"no txt or html to add to pboard");
                    return NO;
                }
                return [self addNotesFromPasteboard:pboard];
            }
        }
	} else if ([[aURL host] length]) {
		//assume find by default
		if (currentNote) {
			[field pushFollowedLink:[[[NoteBookmark alloc] initWithNoteObject:currentNote searchString:[self fieldSearchString]] autorelease]];
		}
		[self searchForString:[aURL host]];
		return YES;
	}
	
	return NO;
}

- (NSString*)stringWithNoteURLsOnPasteboard:(NSPasteboard*)pboard {
	//paste as a file:// URL, so that it can be linked
	
	NSMutableString *allURLsString = [NSMutableString string];
	
	NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
	if ([files isKindOfClass:[NSArray class]]) {
		NSArray *unknownPaths = files;
		NSUInteger i;
		
		if ([notationController currentNoteStorageFormat] != SingleDatabaseFormat) {
			//notes are stored as separate files, so if these paths are in the notes folder then NV can create double-bracketed-links to them instead
			
			NSSet *existingNotes = [notationController notesWithFilenames:files unknownFiles:&unknownPaths];
			if ([existingNotes count]) {
				//create double-bracketed links using these notes' titles
				NSArray *existingArray = [existingNotes allObjects];
				for (i=0; i<[existingArray count]; i++) {
					[allURLsString appendFormat:@"[[%@]]%s", titleOfNote([existingArray objectAtIndex:i]), 
					 (i < [existingArray count] - 1) || [unknownPaths count] ? "\n" : ""];
				}
			}
		}
		//NSLog(@"paths not found in DB: %@", unknownPaths);
		
		for (i=0; i<[unknownPaths count]; i++) {
			NSURL *url = [NSURL fileURLWithPath:[unknownPaths objectAtIndex:i]];
			if (url) {
        NSString *linkFormat = @"<%@>%s";
        NSString *pathString = [url absoluteString];
        NSLog(@"%s",pathString);
        if ([pathString hasSuffix:@"jpg"]   || 
            [pathString hasSuffix:@"jpeg"]  ||
            [pathString hasSuffix:@"gif"]   ||
            [pathString hasSuffix:@"png"])
        {
          currentPreviewMode = [[NSUserDefaults standardUserDefaults] integerForKey:@"markupPreviewMode"];
          if (currentPreviewMode == MarkdownPreview || currentPreviewMode == MultiMarkdownPreview) {
            linkFormat = @"![](%@)%s";
          } else if (currentPreviewMode == TextilePreview) {
            linkFormat = @"!%@()!%s"; 
          }
        }
        [allURLsString appendFormat:linkFormat, 
         [pathString stringByReplacingOccurrencesOfString:@"file://localhost" withString:@"file://"],
         (i < [unknownPaths count] - 1) ? "\n" : ""];          
			}
		}
	}
	return allURLsString;
}

@end
