/*
 *  Spaces.c
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
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "Spaces.h"

Boolean CurrentContextForWindowNumber(NSInteger windowNum, SpaceSwitchingContext *ctx) {
	if (!ctx) return false;
	
	CGSWorkspace windowSpace;
	CGError err = CGSGetWindowWorkspace(_CGSDefaultConnection(), (CGSWindow)windowNum, &windowSpace);
	if (err) {
		printf("CGSGetWindowWorkspace error: %d\n", err);
		return false;
	}
	
	CGSWorkspace currentSpace;
	err = CGSGetWorkspace(_CGSDefaultConnection(), &currentSpace);
	if (err) {
		printf("CGSGetWorkspace error: %d\n", err);
		return false;
	}
	
	ProcessSerialNumber frontPSN;
	OSErr osErr = GetFrontProcess(&frontPSN);
	if (osErr) {
		printf("GetFrontProcess error: %d\n", err);
		return false;
	}
	
	ctx->userSpace = currentSpace;
	ctx->windowSpace = windowSpace;
	ctx->frontPSN = frontPSN;
	
	return true;
}

Boolean CompareContextsAndSwitch(SpaceSwitchingContext *ctxBefore, SpaceSwitchingContext *ctxAfter) {
	if (!ctxBefore || !ctxAfter) {
		printf("null context\n");
		return false;
	}
	
	//contexts are equal; can't do anything
	if (!memcmp(ctxBefore, ctxAfter, sizeof(SpaceSwitchingContext))) {
		printf("equal contexts\n");
		return false;
	}
	
	//if windowspace-before is the same as both userspace-after and windowspace-after
	//and userspace-before was different from windowspace-before
	//and the frontprocess-before was different from frontprocess-after
	//then switch back to userspace-before by bringing the previous app to the front
	//i.e., NV was running in a different space and user switched it; now the user (may) need to switch back
	
	if (ctxBefore->windowSpace == ctxAfter->windowSpace && 
		ctxBefore->windowSpace == ctxAfter->userSpace && 
		ctxBefore->userSpace != ctxBefore->windowSpace &&
		(ctxBefore->frontPSN.highLongOfPSN != ctxAfter->frontPSN.highLongOfPSN ||
		ctxBefore->frontPSN.lowLongOfPSN != ctxAfter->frontPSN.lowLongOfPSN)) {
		
		OSErr err = SetFrontProcess(&ctxBefore->frontPSN);
		if (err) {
			printf("SetFrontProcess error: %d\n", err);
			return false;
		}
		
		return true;
	}
	
	//conditions not right for switch-back; presumably reverting to normal window-toggling
	return false;
}
