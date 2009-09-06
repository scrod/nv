/*
        MultiplePageView.m
        Copyright (c) 1995-2005 by Apple Computer, Inc., all rights reserved.
        Author: Ali Ozer

        View which holds all the pages together in the multiple-page case
*/
/*
 IMPORTANT:  This Apple software is supplied to you by Apple Computer, Inc. ("Apple") in
 consideration of your agreement to the following terms, and your use, installation, 
 modification or redistribution of this Apple software constitutes acceptance of these 
 terms.  If you do not agree with these terms, please do not use, install, modify or 
 redistribute this Apple software.
 
 In consideration of your agreement to abide by the following terms, and subject to these 
 terms, Apple grants you a personal, non-exclusive license, under Apple's copyrights in 
 this original Apple software (the "Apple Software"), to use, reproduce, modify and 
 redistribute the Apple Software, with or without modifications, in source and/or binary 
 forms; provided that if you redistribute the Apple Software in its entirety and without 
 modifications, you must retain this notice and the following text and disclaimers in all 
 such redistributions of the Apple Software.  Neither the name, trademarks, service marks 
 or logos of Apple Computer, Inc. may be used to endorse or promote products derived from 
 the Apple Software without specific prior written permission from Apple. Except as expressly
 stated in this notice, no other rights or licenses, express or implied, are granted by Apple
 herein, including but not limited to any patent rights that may be infringed by your 
 derivative works or by other works in which the Apple Software may be incorporated.
 
 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE MAKES NO WARRANTIES, 
 EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, 
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS 
 USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
 
 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL 
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS 
 OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, 
 REPRODUCTION, MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND 
 WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR 
 OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import <Cocoa/Cocoa.h>
#import "MultiplePageView.h"
#import "GlobalPrefs.h"
#import "NoteObject.h"

@implementation MultiplePageView

- (id)initWithFrame:(NSRect)rect {
    if ((self = [super initWithFrame:rect])) {
		
		textStorage = [[NSTextStorage alloc] init]; 
		
        numPages = 0;
	/* This will set the frame to be whatever's appropriate... */
        [self setPrintInfo:[NSPrintInfo sharedPrintInfo]];
    }
    return self;
}

static float defaultTextPadding(void) {
    static float padding = -1;
    if (padding < 0.0) {
        NSTextContainer *container = [[NSTextContainer alloc] init];
        padding = [container lineFragmentPadding];
        [container release];
    }
    return padding;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)updateFrame {
    if ([self superview]) {
        NSRect rect = NSZeroRect;
        rect.size = [printInfo paperSize];
        rect.size.height = rect.size.height * numPages;
        if (numPages > 1) rect.size.height += [self pageSeparatorHeight] * (numPages - 1);
        rect.size = [self convertSize:rect.size toView:[self superview]];
        [self setFrame:rect];
    }
}

- (void)setPrintInfo:(NSPrintInfo *)anObject {
    if (printInfo != anObject) {
        [printInfo autorelease];
        printInfo = [anObject copyWithZone:[self zone]];
        [self updateFrame];
        [self setNeedsDisplay:YES];	/* Because the page size or margins might change (could optimize this) */
    }
}

- (NSPrintInfo *)printInfo {
    return printInfo;
}

- (void)setNumberOfPages:(unsigned)num {
    if (numPages != num) {
	NSRect oldFrame = [self frame];
        NSRect newFrame;
        numPages = num;
        [self updateFrame];
	newFrame = [self frame];
        if (newFrame.size.height > oldFrame.size.height) {
	    [self setNeedsDisplayInRect:NSMakeRect(oldFrame.origin.x, NSMaxY(oldFrame), oldFrame.size.width, NSMaxY(newFrame) - NSMaxY(oldFrame))];
        }
    }
}

- (unsigned)numberOfPages {
    return numPages;
}
    
- (float)pageSeparatorHeight {
    return 5.0;
}

- (void)dealloc {
	[textStorage release];
    [printInfo release];
    [super dealloc];
}

- (NSSize)documentSizeInPage {
    NSSize paperSize = [printInfo paperSize];
    paperSize.width -= ([printInfo leftMargin] + [printInfo rightMargin]) - defaultTextPadding() * 2.0;
    paperSize.height -= ([printInfo topMargin] + [printInfo bottomMargin]);
    return paperSize;
}

- (NSRect)documentRectForPageNumber:(unsigned)pageNumber {	/* First page is page 0, of course! */
    NSRect rect = [self pageRectForPageNumber:pageNumber];
    rect.origin.x += [printInfo leftMargin] - defaultTextPadding();
    rect.origin.y += [printInfo topMargin];
    rect.size = [self documentSizeInPage];
    return rect;
}

- (NSRect)pageRectForPageNumber:(unsigned)pageNumber {
    NSRect rect;
    rect.size = [printInfo paperSize];
    rect.origin = [self frame].origin;
    rect.origin.y += ((rect.size.height + [self pageSeparatorHeight]) * pageNumber);
    return rect;
}

- (void)drawRect:(NSRect)rect {
    if ([[NSGraphicsContext currentContext] isDrawingToScreen]) {
        NSSize paperSize = [printInfo paperSize];
        unsigned firstPage = rect.origin.y / (paperSize.height + [self pageSeparatorHeight]);
        unsigned lastPage = NSMaxY(rect) / (paperSize.height + [self pageSeparatorHeight]);
        unsigned cnt;
		
		NSAssert(NO, @"MultiplePageView should not be drawing to screen");
        
//        [marginColor set];
//        NSRectFill(rect);

 //       [lineColor set];
        for (cnt = firstPage; cnt <= lastPage; cnt++) {
	    // Draw boundary around the page, making sure it doesn't overlap the document area in terms of pixels
	    NSRect docRect = NSInsetRect([self centerScanRect:[self documentRectForPageNumber:cnt]], -1.0, -1.0);
	    NSFrameRectWithWidth(docRect, 1.0);
        }

        if ([[self superview] isKindOfClass:[NSClipView class]]) {
	    NSColor *backgroundColor = [(NSClipView *)[self superview] backgroundColor];
            [backgroundColor set];
            for (cnt = firstPage; cnt <= lastPage; cnt++) {
		NSRect pageRect = [self pageRectForPageNumber:cnt];
		NSRectFill (NSMakeRect(pageRect.origin.x, NSMaxY(pageRect), pageRect.size.width, [self pageSeparatorHeight]));
            }
        }
    }
}

- (NSTextStorage*)textStorage {
	return textStorage;
}

- (int)printedPageCountForAttributedString:(NSAttributedString*)string {
	//NSPrintInfo *info = printInfo;
	
	NSSize textSize = [self documentSizeInPage];
//	NSTextContainer *textContainer = [[NSTextContainer alloc] initWithContainerSize:textSize];

	NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, textSize.width, textSize.height)];
	[[textView textContainer] setWidthTracksTextView:YES];
    [[textView textStorage] replaceCharactersInRange:NSMakeRange(0, 0) withAttributedString:string];
	
	(void)[[textView layoutManager] glyphRangeForTextContainer:[textView textContainer]];
	float containerHeight = [[textView layoutManager] usedRectForTextContainer:[textView textContainer]].size.height;
	float pageHeight = textSize.height - defaultTextPadding() * 2.0; //[info paperSize].height - ([info topMargin] + [info bottomMargin]);
	
	//NSLog(@"text height: %g, page height: %g", containerHeight, pageHeight);
	[textView release];
	
	return (int)ceil(containerHeight/pageHeight);	
}

+ (NSView *)printableViewWithNotes:(NSArray*)notes {
	
	/// Code for splitting it into pages, mostly taken from TextEdit.  Since each "page" (except the last) has an NSFormFeedCharacter appended to it in the preview field,
	/// we make as many text containers as we have pages, and the typesetter will then force a page break at each form feed.  It's not clear from the docs that this won't
	/// work without a scroll view, but I get an empty view without it.
	
	NSScrollView *theScrollView = [[[NSScrollView alloc] init] autorelease]; // this will retain the other views
	NSClipView *clipView = [[NSClipView alloc] init];
	MultiplePageView *pagesView = [[MultiplePageView alloc] init];
	NSTextStorage *pageStorage = [pagesView textStorage];
	
	[clipView setDocumentView:pagesView];
	[pagesView release]; // retained by the clip view
	
	[theScrollView setContentView:clipView];
	[clipView release]; // retained by the scroll view
	
	[pagesView setPrintInfo:[NSPrintInfo sharedPrintInfo]];
	
	// set up the text object NSTextStorage->NSLayoutManager->((NSTextContainer->NSTextView) * numberOfPages)
	//textStorage = [[NSTextStorage alloc] initWithAttributedString:[abstractView textStorage]];
	NSLayoutManager *lm = [[NSLayoutManager alloc] init];
	[pageStorage addLayoutManager:lm];
	[lm release]; // owned by the text storage
	
	NSAttributedString *formfeed = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%C", NSFormFeedCharacter] attributes:nil];
	NSFont *bodyFont = [[GlobalPrefs defaultPrefs] noteBodyFont];
	
	unsigned i, totalPageCount = 0; //[tableView numberOfSelectedRows];
	for (i=0; i<[notes count]; i++) {
		NSAttributedString *contentString = [[notes objectAtIndex:i] printableStringRelativeToBodyFont:bodyFont];
		
		[pageStorage appendAttributedString:contentString];
		
		if (i < [notes count] - 1) [pageStorage appendAttributedString:formfeed];
		
		unsigned int j, pageCount = [pagesView printedPageCountForAttributedString:contentString];
		[pagesView setNumberOfPages:pageCount + totalPageCount];
		
		for (j=0; j<pageCount; j++) {
			NSTextContainer *textContainer = [[NSTextContainer alloc] initWithContainerSize:[pagesView documentSizeInPage]];
			
			NSTextView *textView = [[NSTextView alloc] initWithFrame:[pagesView documentRectForPageNumber: j + totalPageCount] textContainer:textContainer];
			[textView setHorizontallyResizable:NO];
			[textView setVerticallyResizable:NO];
			
			[pagesView addSubview:textView];
			
			[[[pageStorage layoutManagers] objectAtIndex:0] addTextContainer:textContainer];
			
			[textView release];
			[textContainer release];	
			
			//add per-page header/footers here
		}
		
		totalPageCount += pageCount;
	}
	[formfeed release];
	
	// force layout before printing
	unsigned len;
	unsigned loc = INT_MAX;
	if (loc > 0 && (len = [pageStorage length]) > 0) {
		NSRange glyphRange;
		if (loc >= len) loc = len - 1;
		// Find out which glyph index the desired character index corresponds to
		glyphRange = [[[pageStorage layoutManagers] objectAtIndex:0] glyphRangeForCharacterRange:NSMakeRange(loc, 1) actualCharacterRange:NULL];
		if (glyphRange.location > 0) {
			// Now cause layout by asking a question which has to determine where the glyph is
			(void)[[[pageStorage layoutManagers] objectAtIndex:0] textContainerForGlyphAtIndex:glyphRange.location - 1 effectiveRange:NULL];
		}
	}
	return pagesView; // this has the content
}


+ (void)printNotes:(NSArray*)notes forWindow:(NSWindow*)window {
	
	NSPrintOperation *printOperation = [NSPrintOperation printOperationWithView:[MultiplePageView printableViewWithNotes:notes]];
    [printOperation runOperationModalForWindow:window delegate:nil didRunSelector:NULL contextInfo:NULL];
}

/**** Printing support... ****/

- (BOOL)knowsPageRange:(NSRangePointer)aRange {
    aRange->length = [self numberOfPages];
    return YES;
}

- (NSRect)rectForPage:(int)page {
    return [self documentRectForPageNumber:page-1];  /* Our page numbers start from 0; the kit's from 1 */
}

@end
