//
//  FullscreenWindow.m
//  FullscreenImage
//
//  Created by Matt Gallagher on 2009/08/14.
//  Copyright 2009 Matt Gallagher. All rights reserved.
//
//  Permission is given to use this source code file, free of charge, in any
//  project, commercial or otherwise, entirely at your risk, with the condition
//  that any redistribution (in part or whole) of source code must retain
//  this copyright and permission notice. Attribution in compiled projects is
//  appreciated but not required.
//

#import "FullscreenWindow.h"


@implementation FullscreenWindow


- (BOOL)makeFirstResponder:(NSResponder *)aResponder
{
	BOOL result = [super makeFirstResponder:aResponder];
	return result;
}


- (BOOL)canBecomeKeyWindow
{
	return YES;
}

@end
