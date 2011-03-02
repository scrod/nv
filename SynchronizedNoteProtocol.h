/*
 *  SynchronizedNoteProtocol.h
 *  Notation
 *
 *  Created by Zachary Schneirov on 4/22/06.
 */

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
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


@protocol SynchronizedNote <NSCoding, NSObject>

- (CFUUIDBytes *)uniqueNoteIDBytes;
- (NSDictionary *)syncServicesMD;
//need methods to modify parts of syncServicesMD
- (unsigned int)logSequenceNumber;
- (void)incrementLSN;
- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj;

- (void)setSyncObjectAndKeyMD:(NSDictionary*)aDict forService:(NSString*)serviceName;
//- (void)removeKey:(NSString*)aKey forService:(NSString*)serviceName;
- (void)removeAllSyncMDForService:(NSString*)serviceName;


@end
