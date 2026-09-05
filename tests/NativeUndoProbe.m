/* Standalone public-AppKit experiments, not NV's production undo integration.
 * MRC, TextKit 1, synthetic text only. No general pasteboard or note files.
 * Each scenario runs in a separate process; JSON events deliberately avoid
 * canRedo (which itself posts checkpoint notifications).
 */
#import <Cocoa/Cocoa.h>

static NSMutableArray *events;
static NSMutableArray *checks;
static BOOL recording = YES;
static void Emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    fwrite([data bytes], 1, [data length], stdout); fputc('\n', stdout); fflush(stdout);
}
static void Check(BOOL ok, NSString *name) {
    [checks addObject:@{@"name":name, @"passed":@(ok)}];
}

@interface Probe : NSObject <NSTextViewDelegate, NSWindowDelegate> {
@public
    NSTextView *view;
    NSWindow *window;
    NSUndoManager *manager;
    NSMutableArray *markers;
    NSString *value;
    BOOL accept;
    BOOL automaticMarkers;
    NSUInteger nextMarker;
    NSString *pendingSpanMarker;
}
- (void)log:(NSString *)kind;
- (void)notice:(NSNotification *)notification;
- (void)mark:(NSString *)token;
- (void)setValueForUndo:(NSString *)next;
- (void)capture:(id)sender;
- (void)undoCommand:(id)sender;
- (void)redoCommand:(id)sender;
@end

@implementation Probe
- (id)init {
    if (!(self = [super init])) return nil;
    manager = [[NSUndoManager alloc] init]; markers = [[NSMutableArray alloc] init];
    value = [@"after" copy]; accept = YES;
    // Explicit TK1 matches LinkingEditor; no OS-default layout-engine ambiguity.
    NSTextStorage *storage = [[[NSTextStorage alloc] init] autorelease];
    NSLayoutManager *layout = [[[NSLayoutManager alloc] init] autorelease];
    NSTextContainer *container = [[[NSTextContainer alloc] initWithContainerSize:NSMakeSize(600, 10000)] autorelease];
    [storage addLayoutManager:layout]; [layout addTextContainer:container];
    view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400) textContainer:container];
    [view setDelegate:self]; [view setAllowsUndo:YES]; [view setRichText:YES];
    [view setAutomaticSpellingCorrectionEnabled:NO]; [view setAutomaticTextReplacementEnabled:NO];
    [view setAutomaticQuoteSubstitutionEnabled:NO]; [view setAutomaticDashSubstitutionEnabled:NO];
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,600,400)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO]; [window setContentView:view]; [window setDelegate:self];
    [window makeFirstResponder:view];
    for (NSString *name in @[NSUndoManagerCheckpointNotification, NSUndoManagerDidOpenUndoGroupNotification,
            NSUndoManagerWillCloseUndoGroupNotification, NSUndoManagerDidCloseUndoGroupNotification,
            NSUndoManagerWillUndoChangeNotification, NSUndoManagerDidUndoChangeNotification,
            NSUndoManagerWillRedoChangeNotification, NSUndoManagerDidRedoChangeNotification])
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notice:) name:name object:manager];
    return self;
}
- (NSUndoManager *)undoManagerForTextView:(NSTextView *)textView { return manager; }
- (void)log:(NSString *)kind {
    if (!recording) return;
    NSDictionary *event = @{@"event":kind, @"body":[view string], @"level":@([manager groupingLevel]),
        @"undoing":@([manager isUndoing]), @"redoing":@([manager isRedoing]),
        @"coalescing":@([view isCoalescingUndo]), @"marked":@([view hasMarkedText]),
        @"selection":NSStringFromRange([view selectedRange]), @"markers":[NSArray arrayWithArray:markers]};
    [events addObject:event]; Emit(event);
}
- (void)notice:(NSNotification *)notification { [self log:[notification name]]; }
- (void)textDidChange:(NSNotification *)notification { [self log:@"textDidChange"]; }
- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range replacementString:(NSString *)replacement {
    [self log:@"shouldChange-before-registration"];
    if (pendingSpanMarker && ![manager isUndoing] && ![manager isRedoing]) {
        [manager registerUndoWithTarget:self selector:@selector(mark:) object:pendingSpanMarker];
        [pendingSpanMarker release]; pendingSpanMarker=nil;
        [self log:@"registered-span-before-text"];
    } else if (automaticMarkers && ![manager isUndoing] && ![manager isRedoing] && ![view isCoalescingUndo]) {
        NSString *token=[NSString stringWithFormat:@"group-%lu",(unsigned long)++nextMarker];
        [manager registerUndoWithTarget:self selector:@selector(mark:) object:token];
        [self log:@"registered-marker-before-text"];
    }
    return YES;
}
- (void)capture:(id)sender {
    [self log:@"requested-capture"];
    if (![view hasMarkedText]) [view breakUndoCoalescing];
    [self log:@"captured-or-deferred-marked-text-no-IO"];
}
- (void)undoCommand:(id)sender { if ([manager canUndo]) { [view breakUndoCoalescing]; [manager undo]; } }
- (void)redoCommand:(id)sender { if ([manager canRedo]) { [view breakUndoCoalescing]; [manager redo]; } }
- (void)mark:(NSString *)token {
    [markers addObject:token];
    [manager registerUndoWithTarget:self selector:@selector(mark:) object:token];
}
- (void)setValueForUndo:(NSString *)next {
    if (!accept) return; // Deliberately broken admission, exercised by refusal-inside.
    [manager registerUndoWithTarget:self selector:@selector(setValueForUndo:) object:value];
    [value release]; value = [next copy];
}
- (BOOL)windowShouldClose:(NSWindow *)sender { [self log:@"window-close"]; [NSApp stop:nil]; return YES; }
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [manager removeAllActions]; [view setDelegate:nil]; [window setDelegate:nil];
    [window release]; [view release]; [manager release]; [markers release]; [value release]; [pendingSpanMarker release];
    [super dealloc];
}
@end

static void Pump(Probe *p) {
    // A real run-loop turn, not manually ending AppKit's groups in the observation.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    [p log:@"after-run-loop"];
}
static void Seed(Probe *p, NSString *body) {
    [p->view setString:body]; [p->view setSelectedRange:NSMakeRange([body length],0)];
    [p->manager removeAllActions]; [p->view breakUndoCoalescing]; Pump(p);
}
static void Type(Probe *p, NSString *text) {
    [p->view insertText:text replacementRange:NSMakeRange(NSNotFound,0)]; Pump(p);
}
static NSArray *UndoBodies(Probe *p) {
    NSMutableArray *bodies = [NSMutableArray array];
    [p->view breakUndoCoalescing]; Pump(p);
    for (int i=0; i<12 && [p->manager canUndo]; i++) {
        [p->manager undo]; [bodies addObject:[NSString stringWithString:[p->view string]]]; Pump(p);
    }
    return bodies;
}
static void Fact(NSString *name, id result) { Emit(@{@"observation":name, @"value":result}); }

static void Run(NSString *name, Probe *p) {
    if ([name hasPrefix:@"large-note-"]) {
        NSUInteger count=[[name substringFromIndex:[@"large-note-" length]] integerValue];
        Check(count>0 && count<=32*1024*1024,@"bounded synthetic body");
        if (!count || count>32*1024*1024) return;
        recording=NO;
        [[p->view textContainer] setContainerSize:NSMakeSize(600,CGFLOAT_MAX)];
        NSString *body=[@"line of ordinary text\n" stringByPaddingToLength:count withString:@"line of ordinary text\n" startingAtIndex:0];
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
        [p->view setString:body];
        CFAbsoluteTime loaded=CFAbsoluteTimeGetCurrent();
        // Full layout is an explicit worst-case operation, not NV's viewport-only startup.
        [[p->view layoutManager] ensureLayoutForCharacterRange:NSMakeRange(0,count)];
        CFAbsoluteTime laidOut=CFAbsoluteTimeGetCurrent();
        Check(NSMaxRange([[p->view layoutManager] glyphRangeForTextContainer:[p->view textContainer]]) ==
              [[p->view layoutManager] numberOfGlyphs],@"full document fits the laid-out container");
        [p->view setSelectedRange:NSMakeRange(count,0)];
        [p->view insertText:@"!" replacementRange:NSMakeRange(NSNotFound,0)];
        CFAbsoluteTime edited=CFAbsoluteTimeGetCurrent();
        Check([[p->view string] length]==count+1 && [[p->view string] hasSuffix:@"!"],@"large-note edit retained");
        Fact(@"large-note-cost",@{@"utf16_units":@(count),@"load_ms":@((loaded-start)*1000),
            @"full_layout_ms":@((laidOut-loaded)*1000),@"insert_ms":@((edited-laidOut)*1000)});
    } else if ([name isEqual:@"span-partial-undo"]) {
        Seed(p,@""); p->pendingSpanMarker=[@"span-1" copy];
        Type(p,@"A"); [p->view breakUndoCoalescing]; Type(p,@"B");
        Check([p->manager groupingLevel]==0,@"first capture outside an open undo group");
        [p capture:nil]; p->pendingSpanMarker=[@"span-2" copy];
        Type(p,@"C"); [p->view breakUndoCoalescing]; Type(p,@"D");
        Check([p->manager groupingLevel]==0,@"second capture outside an open undo group"); [p capture:nil];
        NSArray *expected=@[@"ABC",@"AB",@"A",@""];
        NSArray *expectedMarkers=@[@[],@[@"span-2"],@[@"span-2"],@[@"span-2",@"span-1"]];
        for (NSUInteger i=0;i<4;i++) {
            [p->manager undo]; Pump(p);
            Check([[p->view string] isEqual:expected[i]],@"native partial undo keeps the exact remaining effect");
            Check([p->markers isEqual:expectedMarkers[i]],@"span marker distinguishes partial versus complete reversal");
        }
        for (NSString *body in @[@"A",@"AB",@"ABC",@"ABCD"]) {
            [p->manager redo]; Pump(p);
            Check([[p->view string] isEqual:body],@"redo preserves native sub-span granularity");
        }
        Fact(@"span-markers-after-undo-redo",p->markers);
    } else if ([name isEqual:@"span-format"]) {
        Seed(p,@"AB"); p->pendingSpanMarker=[@"format-span" copy];
        [p->view setSelectedRange:NSMakeRange(0,2)]; [p->view underline:nil]; Pump(p);
        Check([p->manager groupingLevel]==0,@"format capture outside an open group"); [p capture:nil];
        p->pendingSpanMarker=[@"typing-span" copy]; [p->view setSelectedRange:NSMakeRange(2,0)]; Type(p,@"C"); [p capture:nil];
        [p->manager undo]; Pump(p);
        Check([[p->view string] isEqual:@"AB"] && [p->markers isEqual:@[@"typing-span"]],@"typing undo crosses only its span");
        Check([[[p->view textStorage] attribute:NSUnderlineStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue]!=0,@"typing undo preserves earlier format span");
        [p->manager undo]; Pump(p);
        Check([p->markers isEqual:@[@"typing-span",@"format-span"]],@"format-first mutation receives the span marker");
        Check([[[p->view textStorage] attribute:NSUnderlineStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue]==0,@"format span undo restores attributes");
        [p->manager redo]; Pump(p); [p->manager redo]; Pump(p);
        Check([[p->view string] isEqual:@"ABC"] && [[[p->view textStorage] attribute:NSUnderlineStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue]!=0,@"span redo restores text and attributes");
    } else if ([name isEqual:@"span-branch"]) {
        Seed(p,@""); p->pendingSpanMarker=[@"span-1" copy];
        Type(p,@"A"); [p->view breakUndoCoalescing]; Type(p,@"B"); [p capture:nil];
        p->pendingSpanMarker=[@"span-2" copy];
        Type(p,@"C"); [p->view breakUndoCoalescing]; Type(p,@"D"); [p capture:nil];
        [p->manager undo]; Pump(p);
        Check([[p->view string] isEqual:@"ABC"] && [p->markers count]==0,@"partial span remains before new branch");
        [p capture:nil]; p->pendingSpanMarker=[@"span-3" copy]; Type(p,@"X"); [p capture:nil];
        Check(![p->manager canRedo],@"new branch clears redo of removed D");
        [p->manager undo]; Pump(p);
        Check([[p->view string] isEqual:@"ABC"] && [p->markers isEqual:@[@"span-3"]],@"new branch undo preserves remaining C");
        [p->manager undo]; Pump(p);
        Check([[p->view string] isEqual:@"AB"] && [p->markers isEqual:@[@"span-3",@"span-2"]],@"remaining old span stays independently undoable");
    } else if ([name isEqual:@"capture-same-event"]) {
        Seed(p,@"");
        [p->view insertText:@"A" replacementRange:NSMakeRange(NSNotFound,0)];
        [p capture:nil];
        Fact(@"capture-grouping-level",@([p->manager groupingLevel]));
        [p->view insertText:@"B" replacementRange:NSMakeRange(NSNotFound,0)]; Pump(p);
        Fact(@"undo-bodies",UndoBodies(p));
        Check([[p->view string] isEqual:@""],@"same-event edits remain reversible");
    } else if ([name isEqual:@"redo-new-edit"]) {
        Seed(p,@""); Type(p,@"A"); [p capture:nil]; Type(p,@"B"); [p capture:nil];
        [p->manager undo]; Pump(p); Check([p->manager canRedo],@"undo initially creates redo");
        Type(p,@"X"); Check(![p->manager canRedo],@"new local edit clears native redo");
        Check([[p->view string] isEqual:@"AX"],@"new branch retains current and fresh input");
    } else if ([name hasPrefix:@"auto-marker-"]) {
        Seed(p,@""); p->automaticMarkers=YES;
        if ([name isEqual:@"auto-marker-composition"]) {
            [p->view setMarkedText:@"n" selectedRange:NSMakeRange(1,0) replacementRange:NSMakeRange(NSNotFound,0)]; Pump(p);
            [p->view setMarkedText:@"ni" selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(NSNotFound,0)]; Pump(p);
            [p->view insertText:@"你" replacementRange:NSMakeRange(NSNotFound,0)]; Pump(p);
        } else {
            Type(p,@"A"); Type(p,@"B");
            if ([name isEqual:@"auto-marker-selection"]) { [p->view moveLeft:nil]; Type(p,@"X"); }
            else if ([name isEqual:@"auto-marker-format"]) { [p->view setSelectedRange:NSMakeRange(0,2)]; [p->view underline:nil]; Pump(p); }
            else if ([name isEqual:@"auto-marker-capture"]) { [p capture:nil]; Type(p,@"C"); }
            else if ([name isEqual:@"auto-marker-replacement"]) { [p->view insertText:@"Q" replacementRange:NSMakeRange(0,2)]; Pump(p); }
            else Type(p,@"C");
        }
        NSString *final=[NSString stringWithString:[p->view string]];
        NSArray *bodies=UndoBodies(p); Fact(@"undo-bodies",bodies); Fact(@"marker-callbacks",p->markers);
        Fact(@"registered-marker-count",@(p->nextMarker));
        Fact(@"one-token-per-native-group-hypothesis",@([bodies count]==[p->markers count]));
        Check([[p->view string] isEqual:@""],@"instrumented undo reaches initial body");
        while ([p->manager canRedo]) { [p->manager redo]; Pump(p); }
        Check([[p->view string] isEqual:final],@"instrumented redo restores exact final body");
    } else if ([name isEqual:@"typing"] || [name isEqual:@"capture-passive"] ||
        [name isEqual:@"capture-break"] || [name hasPrefix:@"marker-"] || [name hasPrefix:@"metadata"]) {
        Seed(p,@"");
        if ([name isEqual:@"marker-before"])
            [p->manager registerUndoWithTarget:p selector:@selector(mark:) object:@"group"];
        if ([name isEqual:@"metadata-before"]) {
            if (@available(macOS 15.0, *)) [p->manager setActionUserInfoValue:@"group" forKey:@"nv.probe.action"];
        }
        for (NSString *letter in @[@"A",@"B",@"C"]) {
            [p->view insertText:letter replacementRange:NSMakeRange(NSNotFound,0)];
            if ([name isEqual:@"marker-every"] || ([name isEqual:@"marker-first"] && [letter isEqual:@"A"]))
                [p->manager registerUndoWithTarget:p selector:@selector(mark:) object:letter];
            if ([name isEqual:@"metadata"] || ([name isEqual:@"metadata-first"] && [letter isEqual:@"A"])) {
                if (@available(macOS 15.0, *)) [p->manager setActionUserInfoValue:letter forKey:@"nv.probe.action"];
            }
            if ([name hasPrefix:@"capture-"]) [p log:@"capture-immutable-value-no-IO"];
            if ([name isEqual:@"capture-break"]) [p->view breakUndoCoalescing];
            Pump(p);
        }
        Check([[p->view string] isEqual:@"ABC"],@"three insertions retain all input");
        if ([name hasPrefix:@"metadata"]) {
            if (@available(macOS 15.0, *)) Fact(@"top-action-metadata",[p->manager undoActionUserInfoValueForKey:@"nv.probe.action"] ?: [NSNull null]);
            else Fact(@"metadata-api",@"unavailable-before-macOS-15");
        }
        NSArray *bodies=UndoBodies(p); Fact(@"undo-bodies",bodies);
        Check([[bodies lastObject] isEqual:@""],@"undo reaches initial empty body");
        if ([name isEqual:@"capture-break"]) Check([bodies isEqual:@[@"AB",@"A",@""]],@"break-at-capture creates three reversible units");
        Fact(@"marker-callbacks",p->markers);
        while ([p->manager canRedo]) { [p->manager redo]; Pump(p); }
        Check([[p->view string] isEqual:@"ABC"],@"redo restores exact original result");
    } else if ([name isEqual:@"selection-backspace"]) {
        Seed(p,@""); Type(p,@"A"); Type(p,@"B");
        [p->view moveLeft:nil]; Type(p,@"X"); [p->view deleteBackward:nil]; Pump(p);
        Check([[p->view string] isEqual:@"AB"],@"insert and backspace at moved selection");
        Fact(@"undo-bodies",UndoBodies(p));
        Check([[p->view string] isEqual:@""],@"undo reaches initial body after selection edits");
    } else if ([name isEqual:@"paste-format"]) {
        Seed(p,@"base ");
        NSPasteboard *pb=[NSPasteboard pasteboardWithUniqueName];
        [pb declareTypes:@[NSPasteboardTypeString] owner:nil]; [pb setString:@"PASTED" forType:NSPasteboardTypeString];
        BOOL pasted=[p->view readSelectionFromPasteboard:pb type:NSPasteboardTypeString];
        Check(pasted,@"private-pasteboard import succeeds");
        [pb releaseGlobally]; Pump(p); [p->view breakUndoCoalescing];
        if (!pasted) return; // A denied platform prerequisite is a failure, not a range exception.
        [p->view setSelectedRange:NSMakeRange(5,6)]; [p->view underline:nil]; Pump(p);
        Check([[p->view string] isEqual:@"base PASTED"],@"formatting keeps body");
        Check([[[p->view textStorage] attribute:NSUnderlineStyleAttributeName atIndex:5 effectiveRange:NULL] integerValue]!=0,@"native attribute edit present");
        [p->manager undo]; Pump(p);
        Check([[[p->view textStorage] attribute:NSUnderlineStyleAttributeName atIndex:5 effectiveRange:NULL] integerValue]==0,@"native undo removes formatting only");
        Fact(@"remaining-undo-bodies",UndoBodies(p));
    } else if ([name isEqual:@"composition"]) {
        Seed(p,@"base ");
        [p->view setMarkedText:@"n" selectedRange:NSMakeRange(1,0) replacementRange:NSMakeRange(NSNotFound,0)]; Pump(p);
        Check([p->view hasMarkedText],@"marked text detectable");
        Fact(@"deadline-visible-but-uncommitted",[p->view string]);
        [p->view setMarkedText:@"ni" selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(NSNotFound,0)]; Pump(p);
        [p->view insertText:@"你" replacementRange:NSMakeRange(NSNotFound,0)]; Pump(p);
        Check(![p->view hasMarkedText] && [[p->view string] isEqual:@"base 你"],@"composition commits once");
        Fact(@"undo-bodies",UndoBodies(p));
        Check([[p->view string] isEqual:@"base "],@"composition undo restores committed baseline");
    } else if ([name isEqual:@"replacement"]) {
        Seed(p,@""); Type(p,@"teh");
        [p->view insertText:@"the" replacementRange:NSMakeRange(0,3)]; Pump(p);
        Fact(@"undo-bodies",UndoBodies(p));
        Check([[p->view string] isEqual:@""],@"explicit correction path preserves reversible input");
    } else if ([name hasPrefix:@"remote-registered-"]) {
        Seed(p,@"cat"); Type(p,@"!"); [p->view breakUndoCoalescing]; Pump(p);
        Type(p,@"?"); [p->view breakUndoCoalescing]; Pump(p);
        BOOL branch=[name hasSuffix:@"branch"];
        BOOL followup=[name hasSuffix:@"followup"];
        if (branch) { [p->manager undo]; Pump(p); Check([p->manager canRedo],@"local redo exists before remote independent action"); }
        NSString *before=[[p->view string] copy];
        NSArray *ranges, *strings;
        if ([name hasSuffix:@"replace"]) {
            ranges=@[[NSValue valueWithRange:NSMakeRange(0,[before length])]]; strings=@[@"犬 🐈 café"];
        } else if ([name hasSuffix:@"multi"]) {
            ranges=@[[NSValue valueWithRange:NSMakeRange(0,0)], [NSValue valueWithRange:NSMakeRange(3,1)]];
            strings=@[@"big ",@"!!"];
        } else { ranges=@[[NSValue valueWithRange:NSMakeRange(0,0)]]; strings=@[@"big "]; }
        Check([p->manager groupingLevel]==0,@"registered remote action starts outside native event group");
        [p->manager beginUndoGrouping];
        BOOL allowed=[p->view shouldChangeTextInRanges:ranges replacementStrings:strings];
        Check(allowed,@"public text-editing gate allows registered change");
        if (allowed) {
            [[p->view textStorage] beginEditing];
            for (NSInteger i=(NSInteger)[ranges count]-1;i>=0;--i)
                [[p->view textStorage] replaceCharactersInRange:[ranges[(NSUInteger)i] rangeValue] withString:strings[(NSUInteger)i]];
            [[p->view textStorage] endEditing]; [p->view didChangeText];
        }
        [p->manager setActionName:@"External Edit"]; [p->manager endUndoGrouping];
        [p->view breakUndoCoalescing]; Pump(p);
        NSString *after=[[p->view string] copy];
        Check(![before isEqual:after],@"registered remote action actually changes contents");
        Check([[p->manager undoActionName] isEqual:@"External Edit"],@"external change has distinct native action name");
        if (branch) Check(![p->manager canRedo],@"registered independent edit replaces native redo branch");
        if (followup) {
            [p->view setSelectedRange:NSMakeRange([after length],0)]; Type(p,@".");
            [p->view breakUndoCoalescing]; Pump(p);
            Check([[p->view string] isEqual:[after stringByAppendingString:@"."]],@"later local typing follows registered external action");
            [p->manager undo]; Pump(p);
            Check([[p->view string] isEqual:after],@"later typing undo leaves the external result intact");
        }
        [p->manager undo]; Pump(p); Check([[p->view string] isEqual:before],@"first undo reverses remote edit, restoring exact native range context");
        if (!branch) { [p->manager undo]; Pump(p); Check([[p->view string] isEqual:@"cat!"],@"older second typing group remains fine grained"); }
        [p->manager undo]; Pump(p); Check([[p->view string] isEqual:@"cat"],@"older first typing group remains fine grained");
        [p->manager redo]; Pump(p); Check([[p->view string] isEqual:@"cat!"],@"redo first native typing group");
        if (!branch) { [p->manager redo]; Pump(p); Check([[p->view string] isEqual:before],@"redo second native typing group"); }
        [p->manager redo]; Pump(p); Check([[p->view string] isEqual:after],@"redo restores exact external result");
        if (followup) {
            [p->manager redo]; Pump(p);
            Check([[p->view string] isEqual:[after stringByAppendingString:@"."]],@"redo restores later local typing separately");
        }
        [before release]; [after release];
    } else if ([name hasPrefix:@"remote-"]) {
        Seed(p,@"cat"); Type(p,@"!"); [p->view breakUndoCoalescing];
        [p->manager disableUndoRegistration];
        if ([name isEqual:@"remote-reset"]) [p->view setString:@"big cat!"];
        else if ([name isEqual:@"remote-notified"]) {
            Check([p->view shouldChangeTextInRange:NSMakeRange(0,0) replacementString:@"big "],@"notified remote insertion allowed");
            [[p->view textStorage] replaceCharactersInRange:NSMakeRange(0,0) withString:@"big "];
            [p->view didChangeText];
        } else if ([name isEqual:@"remote-storage"]) [[p->view textStorage] replaceCharactersInRange:NSMakeRange(0,0) withString:@"big "];
        // remote-title deliberately leaves the text storage unchanged.
        [p->manager enableUndoRegistration]; Pump(p);
        NSString *expected=[name isEqual:@"remote-title"] ? @"cat" : @"big cat";
        BOOL hadUndo=[p->manager canUndo];
        @try { if (hadUndo) [p->manager undo]; }
        @catch (NSException *exception) { Fact(@"native-undo-exception",[exception name]); }
        Fact(@"native-undo-after-remote",@{@"beforeUndoAvailable":@(hadUndo), @"actual":[p->view string],
            @"desired":expected, @"preservedRemoteAndUndidLocal":@([[p->view string] isEqual:expected])});
        if ([name isEqual:@"remote-title"]) Check([[p->view string] isEqual:expected],@"unmodified body retains native undo");
        // Other cases are observations, not claims that untracked replacement is supported.
    } else if ([name hasPrefix:@"refusal-"]) {
        [p->manager setGroupsByEvent:NO];
        [p->manager beginUndoGrouping];
        [p->manager registerUndoWithTarget:p selector:@selector(setValueForUndo:) object:@"before"];
        [p->manager endUndoGrouping]; p->accept=NO;
        if ([name isEqual:@"refusal-inside"]) [p->manager undo];
        else if (p->accept) [p->manager undo];
        BOOL remains=[p->manager canUndo];
        Fact(@"refused-command",@{@"value":p->value,@"canUndo":@(remains),@"canRedo":@([p->manager canRedo])});
        Check([p->value isEqual:@"after"],@"refusal leaves body unchanged");
        Check(remains == [name isEqual:@"refusal-preflight"],@"preflight preserves entry; refusal in callback consumes it");
    } else if ([name isEqual:@"nested-command"]) {
        [p->manager setGroupsByEvent:NO];
        [p->manager beginUndoGrouping]; [p->manager beginUndoGrouping];
        [p->manager registerUndoWithTarget:p selector:@selector(mark:) object:@"one"];
        [p->manager endUndoGrouping];
        Check([p->manager groupingLevel]==1,@"nested close is not completed user command");
        [p->manager registerUndoWithTarget:p selector:@selector(mark:) object:@"two"];
        [p->manager endUndoGrouping]; [p->manager undo];
        Check([p->markers isEqual:@[@"two",@"one"]],@"whole command undone in reverse registration order");
    } else if ([name isEqual:@"interactive"]) {
        [p->window setTitle:@"NV synthetic undo probe — type / undo / IME; close to finish"];
        NSMenu *bar=[[[NSMenu alloc] init] autorelease];
        NSMenuItem *root=[[[NSMenuItem alloc] initWithTitle:@"Probe" action:NULL keyEquivalent:@""] autorelease];
        NSMenu *commands=[[[NSMenu alloc] initWithTitle:@"Probe"] autorelease];
        NSMenuItem *undo=[commands addItemWithTitle:@"Undo" action:@selector(undoCommand:) keyEquivalent:@"z"]; [undo setTarget:p];
        NSMenuItem *redo=[commands addItemWithTitle:@"Redo" action:@selector(redoCommand:) keyEquivalent:@"z"]; [redo setTarget:p];
        [redo setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagShift];
        NSMenuItem *capture=[commands addItemWithTitle:@"Capture boundary (no disk write)" action:@selector(capture:) keyEquivalent:@"s"];
        [capture setTarget:p]; [root setSubmenu:commands]; [bar addItem:root]; [NSApp setMainMenu:bar];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [p->window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [NSApp run];
        Fact(@"interactive",@"human observation only; no automatic pass assertion");
    } else { Check(NO,@"unknown scenario"); }
}

// Independent layout managers: two containers in ONE layout manager would be
// successive pages, not two independent views of the same note.
static NSUInteger sharedViewsDestroyed;
static BOOL sharedUseWindows=YES;
static BOOL sharedInteractive;
static NSUInteger sharedOpenWindows;
static BOOL sharedLifetimeControl;
static void SharedCommand(NSTextView *view, BOOL redo);
static void SharedInputBoundary(NSTextView *view, BOOL entering);
@interface SharedTextView : NSTextView
- (void)probeCapture:(id)sender;
@end
@implementation SharedTextView
- (void)insertText:(id)value replacementRange:(NSRange)range {
    SharedInputBoundary(self,YES);
    @try { [super insertText:value replacementRange:range]; }
    @finally { SharedInputBoundary(self,NO); }
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selected replacementRange:(NSRange)range {
    SharedInputBoundary(self,YES);
    @try { [super setMarkedText:value selectedRange:selected replacementRange:range]; }
    @finally { SharedInputBoundary(self,NO); }
}
- (void)probeUndo:(id)sender { SharedCommand(self,NO); }
- (void)probeRedo:(id)sender { SharedCommand(self,YES); }
- (void)probeCapture:(id)sender {
    BOOL marked=NO;
    for (NSLayoutManager *lm in [[self textStorage] layoutManagers])
        for (NSTextContainer *tc in [lm textContainers]) marked |= [[tc textView] hasMarkedText];
    if (!marked) [self breakUndoCoalescing];
    Fact(@"human-capture-no-IO",@{@"deferredForDraft":@(marked),@"body":[self string]});
}
- (void)dealloc { ++sharedViewsDestroyed; [super dealloc]; }
@end

@interface SharedNote : NSObject <NSTextViewDelegate> {
@public
    NSTextStorage *storage;
    NSUndoManager *undo;
    NSAttributedString *lastObserved;
    NSAttributedString *committed;
    NSUInteger storageNotifications, bodyTransitions, viewNotifications, admissions;
    NSUInteger inputDepth, committedSnapshots, naiveDraftSamples;
    NSRange rememberedSelection;
    BOOL accepting, guardComposition;
}
- (void)freezeCommitted;
@end
@implementation SharedNote
- (id)init {
    if (!(self=[super init])) return nil;
    storage=[[NSTextStorage alloc] initWithString:@"seed"];
    undo=[[NSUndoManager alloc] init]; accepting=YES;
    lastObserved=[storage copy]; committed=[storage copy];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(processed:)
        name:NSTextStorageDidProcessEditingNotification object:storage];
    return self;
}
- (NSUndoManager *)undoManagerForTextView:(NSTextView *)textView { return undo; }
- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range replacementString:(NSString *)text {
    ++admissions;
    if (guardComposition) {
        for (NSLayoutManager *lm in [storage layoutManagers])
            for (NSTextContainer *tc in [lm textContainers])
                if ([tc textView]!=textView && [[tc textView] hasMarkedText]) return NO;
    }
    return accepting;
}
- (void)textDidChange:(NSNotification *)notification {
    ++viewNotifications;
    [self freezeCommitted];
    if (sharedInteractive) Fact(@"human-shared-change",@{@"window":[[(NSTextView *)[notification object] window] title] ?: @"detached",
        @"body":[storage string],@"bodyTransitions":@(bodyTransitions),@"viewNotifications":@(viewNotifications)});
}
- (void)textViewDidChangeSelection:(NSNotification *)notification {
    rememberedSelection=[(NSTextView *)[notification object] selectedRange];
}
- (void)processed:(NSNotification *)notification {
    ++storageNotifications;
    if (![[lastObserved string] isEqual:[storage string]]) ++bodyTransitions;
    [lastObserved release]; lastObserved=[storage copy];
    BOOL marked=NO;
    for (NSLayoutManager *lm in [storage layoutManagers])
        for (NSTextContainer *tc in [lm textContainers]) marked |= [[tc textView] hasMarkedText];
    if (inputDepth && !marked) ++naiveDraftSamples;
}
- (void)freezeCommitted {
    if (inputDepth) return;
    for (NSLayoutManager *lm in [storage layoutManagers])
        for (NSTextContainer *tc in [lm textContainers]) if ([[tc textView] hasMarkedText]) return;
    if (![committed isEqualToAttributedString:storage]) {
        [committed release]; committed=[storage copy]; ++committedSnapshots;
    }
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [undo removeAllActions]; [undo release]; [storage release]; [lastObserved release]; [committed release]; [super dealloc];
}
@end
static void SharedInputBoundary(NSTextView *view, BOOL entering) {
    SharedNote *n=(SharedNote *)[view delegate];
    if (![n isKindOfClass:[SharedNote class]]) return;
    if (entering) ++n->inputDepth;
    else { --n->inputDepth; [n freezeCommitted]; }
}

@interface SharedAttachment : NSObject <NSWindowDelegate> {
@public
    SharedNote *note;
    SharedTextView *text;
    NSLayoutManager *layout;
    NSWindow *window;
}
- (id)initWithNote:(SharedNote *)owner;
- (void)retarget:(SharedNote *)owner;
@end
@implementation SharedAttachment
- (id)initWithNote:(SharedNote *)owner {
    if (!(self=[super init])) return nil;
    note=[owner retain]; layout=[[NSLayoutManager alloc] init];
    NSTextContainer *container=[[[NSTextContainer alloc] initWithContainerSize:NSMakeSize(500,10000)] autorelease];
    [note->storage addLayoutManager:layout]; [layout addTextContainer:container];
    text=[[SharedTextView alloc] initWithFrame:NSMakeRect(0,0,500,300) textContainer:container];
    [text setDelegate:note]; [text setAllowsUndo:YES];
    [text setAutomaticSpellingCorrectionEnabled:NO]; [text setAutomaticTextReplacementEnabled:NO];
    [text setAutomaticQuoteSubstitutionEnabled:NO]; [text setAutomaticDashSubstitutionEnabled:NO];
    if (sharedUseWindows) window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,500,300)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO]; [window setContentView:text]; [window makeFirstResponder:text];
    [window setDelegate:self];
    [text setSelectedRange:NSMakeRange([note->storage length],0)];
    return self;
}
- (void)retarget:(SharedNote *)owner {
    [text breakUndoCoalescing];
    [[layout textStorage] removeLayoutManager:layout];
    [owner->storage addLayoutManager:layout];
    [note release]; note=[owner retain]; [text setDelegate:note];
    [text setSelectedRange:NSMakeRange([note->storage length],0)];
}
- (void)dealloc {
    [window setDelegate:nil];
    [window makeFirstResponder:nil]; [text breakUndoCoalescing];
    [text setDelegate:nil]; [text removeFromSuperview];
    [window setContentView:[[[NSView alloc] init] autorelease]]; [window close];
    [[layout textStorage] removeLayoutManager:layout];
    // Break the explicit TextKit ownership web as well as our own references.
    [[text textContainer] setTextView:nil];
    [layout removeTextContainerAtIndex:0];
    [window release]; [text release]; [layout release]; [note release]; [super dealloc];
}
- (void)windowWillClose:(NSNotification *)notification {
    if (sharedInteractive) {
        Fact(@"human-window-closed",[window title]);
        if (--sharedOpenWindows==0) {
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
        }
    }
}
@end

static void SharedPump(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    // Run-loop timers alone leave this application's window events queued;
    // those events can retain a closed window and invalidate lifetime evidence.
    for (NSUInteger i=0;i<1000;++i) {
        NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
            inMode:NSDefaultRunLoopMode dequeue:YES];
        if (!event) break;
        [NSApp sendEvent:event];
    }
}
static void SharedType(SharedAttachment *a, NSString *string) {
    [a->text insertText:string replacementRange:NSMakeRange(NSNotFound,0)]; SharedPump();
}
static void SharedAppTurn(void) {
    @autoreleasepool {
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer *timer) {
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
        }];
        [NSApp run];
    }
}
static void SharedUndo(SharedNote *n, BOOL redo) {
    for (NSLayoutManager *lm in [n->storage layoutManagers])
        for (NSTextContainer *tc in [lm textContainers]) [[tc textView] breakUndoCoalescing];
    if (redo ? [n->undo canRedo] : [n->undo canUndo]) {
        if (redo) [n->undo redo]; else [n->undo undo];
    }
    SharedPump();
    [n freezeCommitted];
}
static BOOL SharedHasMarkedText(SharedNote *n) {
    for (NSLayoutManager *lm in [n->storage layoutManagers])
        for (NSTextContainer *tc in [lm textContainers]) if ([[tc textView] hasMarkedText]) return YES;
    return NO;
}
static void SharedCommand(NSTextView *view, BOOL redo) {
    SharedNote *n=(SharedNote *)[view delegate];
    if (![n isKindOfClass:[SharedNote class]]) { Fact(@"detached-command-refused",@YES); return; }
    if (n->accepting && !SharedHasMarkedText(n)) SharedUndo(n,redo);
    else Fact(@"command-refused-before-undo-manager",@{@"marked":@(SharedHasMarkedText(n)),@"accepting":@(n->accepting)});
}
static void SharedFact(NSString *label, SharedNote *n) {
    Fact(label,@{@"body":[n->storage string],@"storageNotifications":@(n->storageNotifications),
        @"bodyTransitions":@(n->bodyTransitions),@"viewNotifications":@(n->viewNotifications),
        @"admissions":@(n->admissions),@"destroyedViews":@(sharedViewsDestroyed),
        @"canUndo":@([n->undo canUndo]),@"canRedo":@([n->undo canRedo]),
        @"committedBody":[n->committed string],@"committedSnapshots":@(n->committedSnapshots),
        @"unmarkedNotificationsInsideInput":@(n->naiveDraftSamples)});
}
static SharedNote *survivingNote;
static SharedAttachment *survivingPeer;
static NSString *survivingScenario;
static NSAttributedString *survivingBefore, *survivingAfter;
static void FinishSharedLifetime(void) {
    if (!survivingNote) return;
    SharedNote *x=survivingNote;
    NSUInteger expected=[survivingScenario hasPrefix:@"shared-close-all"]?2:1;
    // Give asynchronous AppKit teardown bounded scheduling opportunities. The
    // dealloc count, NOT the elapsed delay, is the evidence used by the check.
    for (NSUInteger turn=0;turn<3 && sharedViewsDestroyed<expected;++turn) SharedAppTurn();
    SharedFact(@"after-outer-pool-drain",x);
    Check(sharedViewsDestroyed==expected,@"closed original text views actually deallocated before undo/reopen");
    Fact(@"old-views-destruction-confirmed",@(sharedViewsDestroyed==expected));
    if (!survivingPeer) survivingPeer=[[SharedAttachment alloc] initWithNote:x];
    SharedUndo(x,NO); SharedFact(@"detached-origin-undo",x);
    BOOL undone=survivingBefore ? [x->storage isEqualToAttributedString:survivingBefore] : [[x->storage string] isEqual:@"seed"];
    SharedUndo(x,YES); SharedFact(@"detached-origin-redo",x);
    BOOL redone=survivingAfter ? [x->storage isEqualToAttributedString:survivingAfter] : [[x->storage string] isEqual:@"seedA"];
    Check(undone && redone,@"detach/reopen preserves native undo and redo values (including exact attributes for format case)");
    [survivingPeer release]; [x->undo removeAllActions]; [x release]; [survivingScenario release];
    survivingNote=nil; survivingPeer=nil; survivingScenario=nil;
    [survivingBefore release]; [survivingAfter release]; survivingBefore=nil; survivingAfter=nil;
}
static void RunShared(NSString *name) {
    if ([name isEqual:@"shared-empty-lifetime"]) {
        sharedLifetimeControl=YES;
        @autoreleasepool {
            SharedTextView *empty=[[SharedTextView alloc] initWithFrame:NSZeroRect];
            [empty release];
        }
        SharedAppTurn();
        Fact(@"empty-view-destroyed",@(sharedViewsDestroyed));
        return;
    }
    sharedUseWindows=![name hasSuffix:@"-bare"];
    SharedNote *x=[[SharedNote alloc] init], *y=[[SharedNote alloc] init];
    SharedAttachment *a=nil, *b=nil;
    @try {
        // Inner pool is essential: an autoreleased container/undo invocation
        // must not masquerade as an undo-owned retained view in lifetime tests.
        @autoreleasepool {
            a=[[SharedAttachment alloc] initWithNote:x]; b=[[SharedAttachment alloc] initWithNote:x];
            SharedPump(); [x->undo removeAllActions];
            Check(a->text.textStorage==b->text.textStorage && a->layout!=b->layout,@"one storage, independent layout managers");
            x->bodyTransitions=x->storageNotifications=x->viewNotifications=x->admissions=0;
            if ([name isEqual:@"shared-interactive"]) {
                sharedInteractive=YES; sharedOpenWindows=2; x->guardComposition=YES;
                NSMenu *bar=[[[NSMenu alloc] init] autorelease];
                NSMenuItem *root=[[[NSMenuItem alloc] initWithTitle:@"Probe" action:NULL keyEquivalent:@""] autorelease];
                NSMenu *menu=[[[NSMenu alloc] initWithTitle:@"Probe"] autorelease];
                [menu addItemWithTitle:@"Undo" action:@selector(probeUndo:) keyEquivalent:@"z"];
                NSMenuItem *redo=[menu addItemWithTitle:@"Redo" action:@selector(probeRedo:) keyEquivalent:@"z"];
                [redo setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagShift];
                [menu addItemWithTitle:@"Capture boundary (no disk write)" action:@selector(probeCapture:) keyEquivalent:@"s"];
                [menu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
                [root setSubmenu:menu]; [bar addItem:root]; [NSApp setMainMenu:bar];
                [a->window setTitle:@"NV synthetic shared note — A"];
                [b->window setTitle:@"NV synthetic shared note — B"];
                [b->window setFrameOrigin:NSMakePoint(620,100)];
                [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
                [b->window makeKeyAndOrderFront:nil]; [a->window makeKeyAndOrderFront:nil];
                [NSApp activateIgnoringOtherApps:YES]; [NSApp run]; sharedInteractive=NO;
                Fact(@"interactive-scope",@"real input trace only; wrappers retained until completion, not a deallocation test");
            } else if ([name isEqual:@"shared-selection-layout"]) {
                [a->text setSelectedRange:NSMakeRange(0,1)]; [b->text setSelectedRange:NSMakeRange(2,1)];
                Check(NSEqualRanges([a->text selectedRange],NSMakeRange(0,1)),@"other view selection is independent");
                Check(NSEqualRanges(x->rememberedSelection,NSMakeRange(2,1)),@"most recent programmatic selection remembered");
                [a->layout addTemporaryAttribute:NSBackgroundColorAttributeName value:[NSColor yellowColor] forCharacterRange:NSMakeRange(0,1)];
                Check([b->layout temporaryAttribute:NSBackgroundColorAttributeName atCharacterIndex:0 effectiveRange:NULL]==nil,@"search decoration local to layout");
                Check([x->storage attribute:NSBackgroundColorAttributeName atIndex:0 effectiveRange:NULL]==nil,@"decoration absent from authoritative text");
                Check(x->bodyTransitions==0 && ![x->undo canUndo],@"selection and decoration create no body undo");
            } else if ([name isEqual:@"shared-refusal"]) {
                x->accepting=NO; SharedType(a,@"bad"); SharedType(b,@"bad");
                Check([[x->storage string] isEqual:@"seed"] && ![x->undo canUndo],@"shared preflight refusal leaves both views and undo unchanged");
            } else if ([name isEqual:@"shared-paste-format"]) {
                NSPasteboard *pb=[NSPasteboard pasteboardWithUniqueName];
                BOOL ready=[pb writeObjects:@[@"paste"]]; Check(ready,@"private pasteboard available");
                if (ready) {
                    [a->text setSelectedRange:NSMakeRange(0,4)]; [a->text readSelectionFromPasteboard:pb]; SharedPump();
                    [a->text breakUndoCoalescing]; [b->text setSelectedRange:NSMakeRange(0,5)]; [b->text underline:nil]; SharedPump();
                    NSAttributedString *formatted=[x->storage copy];
                    Check([[b->text string] isEqual:@"paste"] && [[x->storage attribute:NSUnderlineStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue]!=0,@"paste and formatting visible to both views");
                    SharedUndo(x,NO); Check([[x->storage attribute:NSUnderlineStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue]==0,@"other-view formatting undone");
                    SharedUndo(x,YES); Check([x->storage isEqualToAttributedString:formatted],@"attributed redo exact"); [formatted release];
                }
                [pb releaseGlobally];
            } else if ([name hasPrefix:@"shared-composition"]) {
                x->guardComposition=[name isEqual:@"shared-composition-guard"];
                [a->text setMarkedText:@"n" selectedRange:NSMakeRange(1,0) replacementRange:NSMakeRange(NSNotFound,0)]; SharedPump();
                Fact(@"composition-scope",@{@"originMarked":@([a->text hasMarkedText]),@"peerMarked":@([b->text hasMarkedText]),@"peerBody":[b->text string]});
                Check([a->text hasMarkedText] && [[b->text string] isEqual:@"seedn"],@"shared storage includes marked draft");
                Check([[x->committed string] isEqual:@"seed"],@"candidate committed snapshot excludes the visible draft");
                if ([name isEqual:@"shared-composition-close"]) {
                    [a->window makeFirstResponder:nil]; [a->window close];
                    Fact(@"marked-after-resign-close",@{@"originMarked":@([a->text hasMarkedText]),@"body":[x->storage string]});
                    return;
                }
                if ([name isEqual:@"shared-composition-cancel"]) {
                    // Explicitly replace the draft with no text, not a claim
                    // about what a real input method's Escape key will do.
                    SharedType(a,@"");
                    Check(![a->text hasMarkedText] && [[x->storage string] isEqual:@"seed"],@"synthetic draft cancellation returns to baseline");
                    return;
                }
                if ([name isEqual:@"shared-composition-peer"] || x->guardComposition) {
                    // Programmatic second-view input is not a real focus/IME
                    // handoff. It exposes whether a note-wide gate is needed.
                    [b->text insertText:@"B" replacementRange:NSMakeRange(0,0)]; SharedPump();
                    Fact(@"peer-input-during-composition",@{@"body":[x->storage string],@"originRange":NSStringFromRange([a->text markedRange])});
                    if (x->guardComposition) Check([[x->storage string] isEqual:@"seedn"],@"candidate gate refuses peer edit while origin has draft");
                    else { SharedType(a,@"你"); SharedFact(@"unguarded-composition-final",x); return; }
                    BOOL remoteApplied=NO;
                    if (!SharedHasMarkedText(x)) { [x->storage replaceCharactersInRange:NSMakeRange(0,0) withString:@"remote"]; remoteApplied=YES; }
                    Check(!remoteApplied,@"candidate remote application defers for any attached marked view");
                }
                [a->text setMarkedText:@"ni" selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(NSNotFound,0)];
                SharedType(a,@"你"); Check(![a->text hasMarkedText] && [[b->text string] isEqual:@"seed你"],@"composition commits once to shared body");
                Check([[x->committed string] isEqual:@"seed你"],@"candidate freezes the committed input after outer input call");
                SharedUndo(x,NO); Check([[x->storage string] isEqual:@"seed"],@"undo committed synthetic composition from shared manager");
                if (x->guardComposition) {
                    [b->text setSelectedRange:NSMakeRange(0,0)];
                    SharedType(b,@"B"); Check([[x->storage string] isEqual:@"Bseed"],@"peer can edit after composition finishes");
                }
            } else {
                SharedType(a,@"A");
                Check([[b->text string] isEqual:@"seedA"] && x->bodyTransitions==1,@"one typed insertion produces one shared body transition");
                if ([name isEqual:@"shared-undo-refusal"]) {
                    x->accepting=NO; SharedCommand(b->text,NO);
                    Check([[x->storage string] isEqual:@"seedA"] && [x->undo canUndo],@"note-wide command refusal does not consume another view's undo");
                    x->accepting=YES; SharedCommand(b->text,NO);
                    Check([[x->storage string] isEqual:@"seed"],@"same undo remains executable after admission recovers");
                } else if ([name isEqual:@"shared-roundtrip"] || [name isEqual:@"shared-replacement"]) {
                    if ([name isEqual:@"shared-replacement"]) {
                        [a->text breakUndoCoalescing];
                        [b->text insertText:@"new" replacementRange:NSMakeRange(0,4)]; SharedPump();
                    }
                    NSAttributedString *expected=[x->storage copy]; SharedUndo(x,NO); SharedFact(@"after-undo",x);
                    Check([[x->storage string] isEqual:[name isEqual:@"shared-replacement"]?@"seedA":@"seed"],@"shared command targets correct previous value");
                    SharedUndo(x,YES); Check([x->storage isEqualToAttributedString:expected],@"cross-view redo restores exact attributed value"); [expected release];
                    if ([name isEqual:@"shared-roundtrip"]) Check(x->committedSnapshots==3,@"edit, undo and redo each freeze once, not once per observing view");
                } else if ([name hasPrefix:@"shared-alternate"]) {
                    if ([name hasSuffix:@"-break"]) [a->text breakUndoCoalescing];
                    [b->text setSelectedRange:NSMakeRange([x->storage length],0)]; SharedType(b,@"B");
                    if ([name hasSuffix:@"-break"]) [b->text breakUndoCoalescing];
                    [a->text setSelectedRange:NSMakeRange([x->storage length],0)]; SharedType(a,@"C");
                    NSMutableArray *bodies=[NSMutableArray array];
                    for (NSUInteger i=0;i<6 && [x->undo canUndo];++i) { SharedUndo(x,NO); [bodies addObject:[NSString stringWithString:[x->storage string]]]; }
                    Fact(@"alternating-view-undo-bodies",bodies);
                    Check([[x->storage string] isEqual:@"seed"],@"all alternating edits undo to baseline");
                } else if ([name isEqual:@"shared-retarget-all-control"]) {
                    [a->layout replaceTextStorage:y->storage];
                    Check([a->text textStorage]==y->storage && [b->text textStorage]==y->storage,
                        @"replaceTextStorage transfers ALL layouts, not just the selected window (documented negative control)");
                } else if ([name isEqual:@"shared-retarget"]) {
                    [a retarget:y]; SharedType(a,@"Y"); SharedUndo(x,NO);
                    SharedFact(@"retarget-old-note",x); SharedFact(@"retarget-new-note",y);
                    Check([[x->storage string] isEqual:@"seed"] && [[y->storage string] isEqual:@"seedY"],@"old-note undo leaves retargeted note's distinct edit intact");
                    SharedUndo(x,YES); SharedUndo(y,NO);
                    Check([[x->storage string] isEqual:@"seedA"] && [[y->storage string] isEqual:@"seed"],@"independent note redo and undo after retarget");
                } else if ([name hasPrefix:@"shared-close-"]) {
                    if ([name hasSuffix:@"-format"]) {
                        survivingBefore=[x->storage copy]; [a->text breakUndoCoalescing];
                        [a->text setSelectedRange:NSMakeRange(0,[x->storage length])];
                        [a->text underline:nil]; SharedPump(); survivingAfter=[x->storage copy];
                        Check(![survivingBefore isEqualToAttributedString:survivingAfter],@"format-only history exists before teardown");
                    }
                    [a release]; a=nil;
                    if ([name hasPrefix:@"shared-close-all"]) { [b release]; b=nil; }
                } else Check(NO,@"known shared scenario");
            }
        }
        for (NSUInteger drain=0;drain<4;++drain) { @autoreleasepool { SharedPump(); } }
        if ([name hasPrefix:@"shared-close-"]) {
            survivingNote=[x retain]; survivingPeer=b; b=nil; survivingScenario=[name copy];
        }
        SharedFact(@"final-shared-observation",x);
    } @finally { [a release]; [b release]; if (!survivingNote) [x->undo removeAllActions]; [y->undo removeAllActions]; [x release]; [y release]; }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        events=[[NSMutableArray alloc] init]; checks=[[NSMutableArray alloc] init];
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSString *name=argc==2 ? [NSString stringWithUTF8String:argv[1]] : @"typing";
        Emit(@{@"scenario":name,@"os":[[NSProcessInfo processInfo] operatingSystemVersionString],
            @"pointerBits":@(sizeof(void*)*8),@"textSystem":@"explicit TextKit 1",
            @"driver":[name hasSuffix:@"interactive"] ? @"human keyboard; own synthetic windows" : @"public method calls and run-loop turns, not physical keyboard events"});
        Probe *p=nil;
        @try {
            if ([name hasPrefix:@"shared-"]) { [NSApp finishLaunching]; RunShared(name); }
            else { p=[[Probe alloc] init]; Run(name,p); }
        }
        @catch (NSException *exception) { Fact(@"unexpected-exception",[exception description]); Check(NO,@"scenario completed without unexpected exception"); }
        [p release];
    }
    @autoreleasepool {
        if (sharedLifetimeControl) {
            for (NSUInteger turn=0;turn<3 && sharedViewsDestroyed<1;++turn) SharedAppTurn();
            Check(sharedViewsDestroyed==1,@"unused-view deallocation control reached");
        }
        @try { FinishSharedLifetime(); }
        @catch (NSException *exception) { Fact(@"unexpected-exception",[exception description]); Check(NO,@"post-drain lifecycle completed"); }
        Fact(@"view-deallocations-after-outer-pool",@(sharedViewsDestroyed));
        BOOL passed=YES; for (NSDictionary *check in checks) if (![check[@"passed"] boolValue]) passed=NO;
        Emit(@{@"result":@(passed),@"checks":checks,@"events":@([events count])});
        recording=NO; [checks release]; [events release];
        return passed ? 0 : 1;
    }
}
