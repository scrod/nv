//
//  StatusItemView.m
//  Notation
//
//  Created by elasticthreads on 07/03/2010.
//  Copyright 2010 elasticthreads. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class AppController;
@interface StatusItemView : NSView {
    __weak AppController *controller;
    BOOL clicked;
}

//@property (nonatomic,readwrite,assign) BOOL clicked;

- (id)initWithFrame:(NSRect)frame controller:(AppController *)ctrlr;
//- (void)setClicked:(BOOL)inBool;
- (void)setInactiveIcon:(id)sender;
- (void)setActiveIcon:(id)sender;

@end
