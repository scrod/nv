//
//  AppController_Preview.m
//  Notation
//
//  Created by Christian Tietze on 15.10.10.
//  Copyright 2010

#import "AppController_Preview.h"

@implementation AppController (Preview)

-(NSString *)noteContent
{
    return [[textView textStorage] string];
}

-(NSInteger)currentPreviewMode
{	
    return currentPreviewMode;
}

@end
