#import "FocusRingScrollView.h"
#import "GlobalPrefs.h"
#import "BodyScroller.h"
#import "LinkingEditor.h"

@implementation FocusRingScrollView


- (id)init {
	if ([super init]) {
		hasFocus = NO;
		
	}
	return self;
}

#if DELAYED_LAYOUT
- (id) initWithCoder: (NSCoder *) decoder
{
	BOOL useSetClass = NO;
	BOOL useDecodeClassName = NO;
	
	if ([decoder respondsToSelector: @selector(setClass:forClassName:)] ) {
		useSetClass = YES;
		[(NSKeyedUnarchiver *)decoder setClass:[BodyScroller class]  forClassName: @"NSScroller"];
		
	} else if ( [decoder respondsToSelector: @selector(decodeClassName:asClassName:)] ) {
		useDecodeClassName = YES;
		[(NSUnarchiver *) decoder decodeClassName: @"NSScroller"  asClassName: @"BodyScroller"];
	}
	
	self = [super initWithCoder:decoder];
	
	if (useSetClass) {
		[(NSKeyedUnarchiver *) decoder setClass: [NSScroller class] forClassName: @"NSScroller"];
	} else if ( useDecodeClassName ) {
		[(NSUnarchiver *) decoder decodeClassName: @"NSScroller" asClassName: @"NSScroller"];
	}
	
	return self;
}
#endif

- (void)awakeFromNib {
	window = [self window];
	
	//NSWindowDidBecomeKeyNotification
	//NSWindowDidResignKeyNotification
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowChangedKeyNotification:)
												 name:NSWindowDidBecomeKeyNotification object:window];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowChangedKeyNotification:)
												 name:NSWindowDidResignKeyNotification object:window];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
		
	[super dealloc];
}

- (void)windowChangedKeyNotification:(NSNotification*)aNote {
	[self setKeyboardFocusRingNeedsDisplayInRect:[self bounds]];
}

- (void)setHasFocus:(BOOL)value {
	hasFocus = [[GlobalPrefs defaultPrefs] drawFocusRing] ? value : NO;
	[self setKeyboardFocusRingNeedsDisplayInRect:[self bounds]];
	//[self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect {
	[super drawRect:rect];
	
	if (hasFocus && [window isKeyWindow]) {
		NSSetFocusRingStyle(NSFocusRingOnly);
		
		NSRectFill(rect);
	}
}

@end
