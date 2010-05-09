//
//  SearchCommand.m
//  Notation
//
//  Created by Greg D Bell on 9-5-10.
//  Copyright 2010 Orange Peel Media Ltd. All rights reserved.
//

#import "SearchCommand.h"
#import "AppController.h"

@implementation SearchCommand

- (id)performDefaultImplementation
{
	NSString *searchTerm = [self directParameter];
	[(AppController *)[NSApp delegate] searchForString:searchTerm];	
	return self;
}

@end
