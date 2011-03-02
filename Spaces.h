/*
 *  Spaces.h
 *  Notation
 *
 *  Created by Zachary Schneirov on 1/22/11.
 
  Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */

#include <Carbon/Carbon.h>

typedef int CGSConnection;
typedef int CGSWorkspace;
typedef int CGSWindow;
typedef int32_t CGError;

extern CGSConnection _CGSDefaultConnection(void);
extern CGError CGSGetWorkspace(const CGSConnection cid, CGSWorkspace *workspace);
extern CGError CGSGetWindowWorkspace(const CGSConnection cid, const CGSWindow wid, CGSWorkspace *workspace);
extern CGError CGSSetWorkspace(const CGSConnection cid, CGSWorkspace workspace);

typedef struct _SpaceSwitchingContext {
	CGSWorkspace userSpace;
	CGSWorkspace windowSpace;
	ProcessSerialNumber frontPSN;
} SpaceSwitchingContext;

Boolean CurrentContextForWindowNumber(NSInteger windowNum, SpaceSwitchingContext *ctx);
Boolean CompareContextsAndSwitch(SpaceSwitchingContext *ctxBefore, SpaceSwitchingContext *ctxAfter);

