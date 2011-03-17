//
//  LinkingEditor_Indentation.h
//  Notation
//
//  Created by Zachary Schneirov on 12/10/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
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


#import <Cocoa/Cocoa.h>

#import "LinkingEditor.h"

@interface LinkingEditor (Indentation)

- (IBAction)shiftLeftAction:(id)sender;
- (IBAction)shiftRightAction:(id)sender;


@end
