/* Exploratory consumer-side metadata probe. Included after the harness helpers.
 * Owns one uniquely named subtree; never changes production notes or resolves
 * versions. Values are synthetic. Preservation is observational, not asserted
 * as a universal Foundation/provider contract. */
#include <sys/clonefile.h>
#include <CommonCrypto/CommonDigest.h>

static NSDictionary *MetadataFlagVariants(void) {
	return @{@"sync": @(XATTR_FLAG_SYNCABLE),
		@"incarnation": @(XATTR_FLAG_SYNCABLE | XATTR_FLAG_ONLY_SAVING),
		@"private-incarnation": @(XATTR_FLAG_SYNCABLE | XATTR_FLAG_ONLY_SAVING | XATTR_FLAG_NO_EXPORT),
		@"revision": @(XATTR_FLAG_SYNCABLE | XATTR_FLAG_CONTENT_DEPENDENT),
		@"local-seal": @(XATTR_FLAG_ONLY_SAVING),
		@"never": @(XATTR_FLAG_SYNCABLE | XATTR_FLAG_NEVER_PRESERVE)};
}

static NSString *MetadataName(NSString *label) {
	NSString *base = [@"com.notationalvelocity.contract.metadata-v1." stringByAppendingString:label];
	char *name = xattr_name_with_flags([base UTF8String], [MetadataFlagVariants()[label] unsignedLongLongValue]);
	NSString *result = name ? [NSString stringWithUTF8String:name] : nil;
	free(name);
	return result;
}

static NSString *MetadataHash(NSData *data) {
	if (!data) return @"absent";
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256([data bytes], (CC_LONG)[data length], digest);
	NSMutableString *result = [NSMutableString string];
	for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
	return result;
}

static NSDictionary *MetadataNames(void) {
	NSMutableDictionary *names = [NSMutableDictionary dictionary];
	for (NSString *label in MetadataFlagVariants()) names[label] = MetadataName(label);
	return names;
}

static NSDictionary *MetadataSnapshotWithNames(NSURL *url, NSTimeInterval timeout, NSDictionary *names, BOOL readBody) {
	// Separate observations, not a coherent production admission snapshot.
	NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
	NSMutableDictionary *bodyBindings = [NSMutableDictionary dictionary];
	NSError *bodyError = nil;
	NSData *body = readBody ? CoordinatedRead(FreshURL(url), &bodyError) : nil;
	NSString *bodyHash = MetadataHash(body);
	for (NSString *label in names) {
		NSError *error = nil;
		NSData *value = CoordinatedXAttrData(FreshURL(url), names[label],
			NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly, &error);
		attributes[label] = value ? MetadataHash(value) : ErrorCode(error);
		id decoded = value ? [NSPropertyListSerialization propertyListWithData:value options:0 format:NULL error:NULL] : nil;
		bodyBindings[label] = @([decoded isKindOfClass:[NSDictionary class]] && body &&
			[decoded[@"bodySHA256"] isEqual:bodyHash]);
	}
	NSError *error = nil;
	NSDictionary *identity = CopyProviderIdentity(FreshURL(url), MIN(timeout, 5.0), &error);
	NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObjectsAndKeys:
		attributes, @"attributes", bodyBindings, @"bodyBindings", ErrorCode(error), @"providerError",
		ErrorCode(bodyError), @"bodyError", bodyHash, @"bodyHash", names, @"names",
		ResourceValue(FreshURL(url), NSURLUbiquitousItemIsUploadedKey, NULL) ?: [NSNull null], @"uploaded",
		ResourceValue(FreshURL(url), NSURLUbiquitousItemIsUploadingKey, NULL) ?: [NSNull null], @"uploading",
		ErrorCode(ResourceValue(FreshURL(url), NSURLUbiquitousItemUploadingErrorKey, NULL)), @"uploadError",
		[ResourceValue(FreshURL(url), NSURLUbiquitousItemDownloadingStatusKey, NULL) description] ?: @"unknown", @"downloadStatus", nil];
	if (identity) {
		result[@"providerItemHash"] = MetadataHash([identity[@"item"] dataUsingEncoding:NSUTF8StringEncoding]);
		result[@"providerDomainHash"] = MetadataHash([identity[@"domain"] dataUsingEncoding:NSUTF8StringEncoding]);
	}
	return result;
}

static NSDictionary *MetadataSnapshot(NSURL *url, NSTimeInterval timeout) {
	return MetadataSnapshotWithNames(url, timeout, MetadataNames(), YES);
}

static BOOL MetadataSeed(NSURL *url, NSData *body, NSData *envelope, NSError **outError) {
	if (!CoordinatedWrite(url, body, outError)) return NO;
	for (NSString *label in MetadataFlagVariants())
		if (!CoordinatedSetXAttrData(url, MetadataName(label), envelope, outError)) return NO;
	return YES;
}

static BOOL MetadataCopy(NSURL *source, NSURL *destination, BOOL rawClone, NSError **outError) {
	NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
	__block BOOL copied = NO;
	__block NSError *accessError = nil;
	NSError *coordinationError = nil;
	[coordinator coordinateReadingItemAtURL:source options:0 writingItemAtURL:destination
		options:0 error:&coordinationError byAccessor:^(NSURL *from, NSURL *to) {
			if (rawClone) {
				copied = clonefile([from fileSystemRepresentation], [to fileSystemRepresentation], 0) == 0;
				if (!copied) accessError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
			} else copied = [[NSFileManager defaultManager] copyItemAtURL:from toURL:to error:&accessError];
		}];
	if (!copied && outError) *outError = accessError ?: coordinationError;
	return copied;
}

static void MetadataReport(NSString *label, NSDictionary *value) {
	NSData *json = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
	Report(@"OBSERVE", [@"AV-METADATA-" stringByAppendingString:label],
		[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease]);
}

static void MetadataServices(NSURL *url, NSTimeInterval timeout) {
	// Enumerate public service names only. Never guess a private XPC protocol.
	// The API's copied block owns result even if our bounded wait expires.
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	[[NSFileManager defaultManager] getFileProviderServicesForItemAtURL:url completionHandler:
		^(NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *services, NSError *error) {
			@synchronized(result) {
				result[@"names"] = [[services allKeys] sortedArrayUsingSelector:@selector(compare:)] ?: @[];
				result[@"error"] = ErrorCode(error);
				result[@"completed"] = @YES;
			}
		}];
	BOOL completed = WaitFor(MIN(timeout, 5.0), ^BOOL{
		@synchronized(result) { return [result[@"completed"] boolValue]; }
	});
	NSDictionary *snapshot;
	@synchronized(result) { snapshot = [[result copy] autorelease]; }
	MetadataReport(@"provider-services", completed ? snapshot : @{@"completed": @NO});
}

static int RunMetadataProbe(NSURL *root, NSTimeInterval timeout) {
	NSURL *session = [root URLByAppendingPathComponent:[@"nv-api-metadata-" stringByAppendingString:[[NSUUID UUID] UUIDString]] isDirectory:YES];
	NSError *error = nil;
	if (!CoordinatedCreateDirectory(session, &error)) {
		ReportError(@"FAIL", @"AV-METADATA-create", error); return 1;
	}
	Report(@"READY", @"AV-METADATA-session", [session path]);
	NSMutableDictionary *intents = [NSMutableDictionary dictionary];
	for (NSString *label in MetadataFlagVariants()) {
		NSMutableArray *row = [NSMutableArray array];
		for (NSUInteger intent = XATTR_OPERATION_INTENT_COPY; intent <= XATTR_OPERATION_INTENT_BACKUP; intent++)
			[row addObject:@(xattr_preserve_for_intent([MetadataName(label) UTF8String], (unsigned int)intent) != 0)];
		intents[label] = row;
	}
	MetadataReport(@"copy-save-share-sync-backup", intents);
	MetadataReport(@"encoded-names", MetadataNames());
	Report([intents[@"incarnation"] isEqual:@[@NO,@YES,@NO,@YES,@YES]] ? @"PASS" : @"OBSERVE",
		@"AV-METADATA-SX-policy", @"desired policy; older runtimes may omit unsupported flag bits when encoding names");
	NSData *body = UniquePatternData(8192, 42);
	NSData *nextBody = PatternData(8192, 43);
	NSDictionary *envelopeObject = @{@"schema": @1, @"collection": [[NSUUID UUID] UUIDString],
		@"birth": [[NSUUID UUID] UUIDString], @"operation": [[NSUUID UUID] UUIDString],
		@"bodySHA256": MetadataHash(body)};
	NSData *envelope = [NSPropertyListSerialization dataWithPropertyList:envelopeObject
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
	NSMutableDictionary *nextEnvelopeObject = [[envelopeObject mutableCopy] autorelease];
	nextEnvelopeObject[@"operation"] = [[NSUUID UUID] UUIDString];
	nextEnvelopeObject[@"bodySHA256"] = MetadataHash(nextBody);
	NSData *nextEnvelope = [NSPropertyListSerialization dataWithPropertyList:nextEnvelopeObject
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
	NSMutableDictionary *observations = [NSMutableDictionary dictionary];
	NSURL *source = [session URLByAppendingPathComponent:@"source.bin"];
	if (!envelope || !nextEnvelope || !MetadataSeed(source, body, envelope, &error)) {
		ReportError(@"FAIL", @"AV-METADATA-seed", error); return 1;
	}
	observations[@"source.bin"] = MetadataSnapshot(source, timeout);
	BOOL sourceBound = YES;
	for (NSNumber *bound in [observations[@"source.bin"][@"bodyBindings"] allValues])
		sourceBound &= [bound boolValue];
	Report(sourceBound ? @"PASS" : @"FAIL", @"AV-METADATA-body-binding-positive",
		@"seeded envelope digests match the actual source body");
	for (NSString *operation in @[@"foundation-copy", @"raw-clone", @"safe-save", @"atomic-save", @"inplace-save", @"rename",
		@"stage-incarnation-default", @"stage-incarnation-new", @"stage-revision-default", @"stage-revision-new"]) {
		NSURL *url = [session URLByAppendingPathComponent:[operation stringByAppendingString:@".bin"]];
		BOOL ok;
		if ([operation isEqual:@"foundation-copy"] || [operation isEqual:@"raw-clone"])
			ok = MetadataCopy(source, url, [operation isEqual:@"raw-clone"], &error);
		else {
			ok = MetadataSeed(url, body, envelope, &error);
			if (ok && [operation isEqual:@"safe-save"]) ok = CoordinatedSafeReplace(FreshURL(url), nextBody, &error) != nil;
			if (ok && [operation isEqual:@"atomic-save"]) ok = CoordinatedWrite(url, nextBody, &error);
			if (ok && [operation isEqual:@"inplace-save"]) ok = CoordinatedInPlaceWrite(url, nextBody, &error);
			if (ok && [operation hasPrefix:@"stage-"]) {
				NSString *label = [operation containsString:@"incarnation"] ? @"incarnation" : @"revision";
				NSFileManagerItemReplacementOptions options = [operation hasSuffix:@"-new"] ?
					NSFileManagerItemReplacementUsingNewMetadataOnly : 0;
				ok = CoordinatedSafeReplaceWithBackupPerformingAccessorAction(FreshURL(url), nextBody,
					nil, options, nil, MetadataName(label), nextEnvelope, &error) != nil;
			}
			if (ok && [operation isEqual:@"rename"]) {
				NSURL *moved = [session URLByAppendingPathComponent:@"renamed.bin"];
				ok = CoordinatedMove(url, moved, &error); url = moved;
			}
		}
		if (!ok) {
			ReportError([operation isEqual:@"raw-clone"] ? @"OBSERVE" : @"FAIL", operation, error);
			continue;
		}
		observations[[url lastPathComponent]] = MetadataSnapshot(FreshURL(url), timeout);
		MetadataReport(operation, observations[[url lastPathComponent]]);
		if ([operation hasSuffix:@"save"]) {
			BOOL acceptedStale = NO;
			for (NSNumber *bound in [observations[[url lastPathComponent]][@"bodyBindings"] allValues])
				acceptedStale |= [bound boolValue];
			Report(acceptedStale ? @"FAIL" : @"PASS", @"AV-METADATA-body-binding-negative",
				@"changed body never validates against the old envelope (missing metadata also rejects)");
		}
	}
	MetadataReport(@"source", observations[@"source.bin"]);
	MetadataServices(source, timeout);
	NSData *manifest = [NSPropertyListSerialization dataWithPropertyList:
		@{@"schema": @1, @"names": MetadataNames(), @"envelopeHash": MetadataHash(envelope), @"observations": observations}
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
	if (!manifest || !CoordinatedWrite([session URLByAppendingPathComponent:@"origin.plist"], manifest, &error))
		ReportError(@"FAIL", @"AV-METADATA-manifest", error);
	Report(@"READY", @"AV-METADATA-peer", @"run metadata-inspect SESSION on the second Mac; test subtree retained");
	return failures ? 1 : 0;
}

static int RunMetadataInspect(NSURL *session, NSTimeInterval timeout) {
	// A peer marker is only a wakeup: inspect each actual item independently.
	NSError *error = nil;
	NSData *bytes = CoordinatedRead([session URLByAppendingPathComponent:@"origin.plist"], &error);
	NSDictionary *manifest = bytes ? [NSPropertyListSerialization propertyListWithData:bytes options:0 format:NULL error:&error] : nil;
	if (![manifest isKindOfClass:[NSDictionary class]] || ![manifest[@"schema"] isEqual:@1] ||
		![manifest[@"observations"] isKindOfClass:[NSDictionary class]]) {
		ReportError(@"FAIL", @"AV-METADATA-read-manifest", error); return 1;
	}
	NSDictionary *names = manifest[@"names"];
	if (![names isKindOfClass:[NSDictionary class]] || [names count] != [MetadataFlagVariants() count]) {
		Report(@"FAIL", @"AV-METADATA-manifest", @"exact origin attribute names required; use a fresh fixture"); return 1;
	}
	for (id label in names) {
		if (![label isKindOfClass:[NSString class]] || ![names[label] isKindOfClass:[NSString class]] ||
			![names[label] hasPrefix:@"com.notationalvelocity.contract.metadata-v1."]) {
			Report(@"FAIL", @"AV-METADATA-manifest", @"invalid attribute name"); return 1;
		}
	}
	for (NSString *leaf in manifest[@"observations"]) {
		if (![leaf isKindOfClass:[NSString class]] || ![[leaf lastPathComponent] isEqual:leaf] ||
			![leaf hasSuffix:@".bin"]) { Report(@"FAIL", @"AV-METADATA-manifest", @"invalid leaf"); return 1; }
		NSDictionary *before = manifest[@"observations"][leaf];
		if (![before isKindOfClass:[NSDictionary class]]) {
			Report(@"FAIL", @"AV-METADATA-manifest", @"invalid observation"); return 1;
		}
		NSDictionary *now = MetadataSnapshotWithNames([session URLByAppendingPathComponent:leaf], timeout, names, YES);
		MetadataReport(leaf, @{@"observation": now,
			@"sameProviderItem": @([now[@"providerItemHash"] isEqual:before[@"providerItemHash"]]),
			@"sameProviderDomain": @([now[@"providerDomainHash"] isEqual:before[@"providerDomainHash"]])});
	}
	MetadataServices([session URLByAppendingPathComponent:@"source.bin"], timeout);
	return failures ? 1 : 0;
}

// One-operation-per-process driver: fresh observers on both Macs, no GUI or
// private provider APIs. Only fixed leaves below a generated binding session.
static int RunBindingProbe(NSURL *root, NSString *action, NSString *leaf, NSTimeInterval timeout) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSError *error = nil;
	if ([action isEqual:@"prepare"]) {
		NSURL *session = [root URLByAppendingPathComponent:[@"nv-api-binding-" stringByAppendingString:[[NSUUID UUID] UUIDString]] isDirectory:YES];
		NSData *body = UniquePatternData(8192, 71);
		NSDictionary *claim = @{@"schema": @1, @"birth": [[NSUUID UUID] UUIDString],
			@"operation": [[NSUUID UUID] UUIDString], @"bodySHA256": MetadataHash(body)};
		NSData *data = [NSPropertyListSerialization dataWithPropertyList:claim format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
		BOOL ok = data && CoordinatedCreateDirectory(session, &error) &&
			CoordinatedCreateDirectory([session URLByAppendingPathComponent:@"Trash"], &error) &&
			MetadataSeed([session URLByAppendingPathComponent:@"note.bin"], body, data, &error) &&
			MetadataCopy([session URLByAppendingPathComponent:@"note.bin"], [session URLByAppendingPathComponent:@"original.bin"], NO, &error) &&
			CoordinatedWrite([session URLByAppendingPathComponent:@"binding.plist"], data, &error);
		if (!ok) { ReportError(@"FAIL", @"AV-BIND-prepare", error); return 1; }
		Report(@"READY", @"AV-BIND-session", [session path]); return 0;
	}
	NSSet *leaves = [NSSet setWithArray:@[@"note.bin", @"renamed.bin", @"copy.bin", @"original.bin", @"Trash/note.bin", @"intent.plist"]];
	if (![[root lastPathComponent] hasPrefix:@"nv-api-binding-"] || ![leaves containsObject:leaf] ||
		!CoordinatedRead([root URLByAppendingPathComponent:@"binding.plist"], &error)) {
		Report(@"FAIL", @"AV-BIND-scope", @"generated session marker and fixed test leaf required"); return 1;
	}
	NSURL *url = [root URLByAppendingPathComponent:leaf];
	// Use fixed #S name for the binding experiment: #X encoding differs by OS.
	NSDictionary *names = @{@"sync": @"com.notationalvelocity.contract.metadata-v1.sync#S"};
	if ([action isEqual:@"observe"] || [action isEqual:@"metadata"]) {
		MetadataReport(@"binding", MetadataSnapshotWithNames(url, timeout, names, [action isEqual:@"observe"])); return 0;
	}
	BOOL ok = NO;
	if ([action isEqual:@"challenge"] || [action isEqual:@"reply"] || [action isEqual:@"ack"] || [action isEqual:@"relay"]) {
		if (![@[@"note.bin", @"copy.bin"] containsObject:leaf]) {
			Report(@"FAIL", @"AV-BIND-handshake-scope", @"note.bin or copy.bin required"); return 1;
		}
		NSData *old = CoordinatedXAttrData(url, names[@"sync"], 0, &error);
		id decoded = old ? [NSPropertyListSerialization propertyListWithData:old options:NSPropertyListMutableContainers format:NULL error:&error] : nil;
		NSData *body = CoordinatedRead(url, &error);
		if (![decoded isKindOfClass:[NSMutableDictionary class]] || !body ||
			![decoded[@"bodySHA256"] isEqual:MetadataHash(body)]) {
			Report(@"FAIL", @"AV-BIND-handshake-claim", @"valid body-bound synthetic claim required"); return 1;
		}
		NSMutableDictionary *claim = decoded;
		if ([action isEqual:@"challenge"]) {
			claim[@"challenge"] = [[NSUUID UUID] UUIDString];
			[claim removeObjectForKey:@"reply"]; [claim removeObjectForKey:@"ack"];
		} else if (![claim[@"challenge"] isKindOfClass:[NSString class]]) {
			Report(@"FAIL", @"AV-BIND-handshake-challenge", @"challenge required"); return 1;
		} else if ([action isEqual:@"reply"]) {
			claim[@"reply"] = [[NSUUID UUID] UUIDString]; [claim removeObjectForKey:@"ack"];
		} else if ([action isEqual:@"ack"]) {
			if (![claim[@"reply"] isKindOfClass:[NSString class]]) {
				Report(@"FAIL", @"AV-BIND-handshake-reply", @"reply required"); return 1;
			}
			claim[@"ack"] = claim[@"reply"];
		}
		if ([action isEqual:@"relay"]) {
			url = [root URLByAppendingPathComponent:[leaf isEqual:@"note.bin"] ? @"copy.bin" : @"note.bin"];
			NSData *targetBody = CoordinatedRead(url, &error);
			if (!targetBody || ![body isEqual:targetBody]) {
				Report(@"FAIL", @"AV-BIND-handshake-relay", @"existing equal-body synthetic target required"); return 1;
			}
		}
		NSData *data = [NSPropertyListSerialization dataWithPropertyList:claim format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
		ok = data && CoordinatedSetXAttrData(url, names[@"sync"], data, &error);
		if (ok) MetadataReport(@"handshake", @{@"leaf": [url lastPathComponent],
			@"challenge": claim[@"challenge"], @"reply": claim[@"reply"] ?: @"none",
			@"ack": claim[@"ack"] ?: @"none"});
	} else if ([action isEqual:@"rename"])
		ok = CoordinatedMove(url, [root URLByAppendingPathComponent:@"renamed.bin"], &error);
	else if ([action isEqual:@"unrename"])
		ok = CoordinatedMove(url, [root URLByAppendingPathComponent:@"note.bin"], &error);
	else if ([action isEqual:@"copy"])
		ok = MetadataCopy(url, [root URLByAppendingPathComponent:@"copy.bin"], NO, &error);
	else if ([action isEqual:@"trash"])
		ok = CoordinatedMove(url, [root URLByAppendingPathComponent:@"Trash/note.bin"], &error);
	else if ([action isEqual:@"untrash"])
		ok = CoordinatedMove(url, [root URLByAppendingPathComponent:@"note.bin"], &error);
	else if ([action isEqual:@"delete"])
		ok = CoordinatedDelete(url, &error);
	else if ([action isEqual:@"restore-copy"])
		ok = MetadataCopy([root URLByAppendingPathComponent:@"original.bin"], url, NO, &error);
	else if ([action isEqual:@"atomic"])
		ok = CoordinatedWrite(url, UniquePatternData(8192, 73), &error);
	else if ([action isEqual:@"evict"]) {
		ok = WaitUntilUploaded(url, MIN(timeout, 30.0)) && [manager evictUbiquitousItemAtURL:url error:&error] &&
			WaitUntilNotDownloaded(url, MIN(timeout, 30.0));
		Report(ok ? @"PASS" : @"OBSERVE", @"AV-BIND-evict", ErrorCode(error));
		MetadataReport(@"binding", MetadataSnapshotWithNames(url, timeout, names, NO)); return 0;
	} else if ([action isEqual:@"materialize"])
		ok = [manager startDownloadingUbiquitousItemAtURL:url error:&error] && WaitUntilCurrent(url, MIN(timeout, 30.0));
	else if ([action isEqual:@"safe"] || [action isEqual:@"fresh-birth"] || [action isEqual:@"intent"]) {
		NSData *old = CoordinatedXAttrData(url, names[@"sync"], 0, &error);
		id decoded = old ? [NSPropertyListSerialization propertyListWithData:old options:NSPropertyListMutableContainers format:NULL error:&error] : nil;
		if (![decoded isKindOfClass:[NSMutableDictionary class]] || ![decoded[@"birth"] isKindOfClass:[NSString class]]) {
			Report(@"FAIL", @"AV-BIND-claim", @"missing valid synthetic birth claim"); return 1;
		}
		NSData *body = [action isEqual:@"safe"] ? UniquePatternData(8192, 72) : CoordinatedRead(url, &error);
		NSMutableDictionary *claim = decoded;
		claim[@"parent"] = claim[@"operation"] ?: @"none";
		claim[@"operation"] = [[NSUUID UUID] UUIDString];
		if ([action isEqual:@"fresh-birth"]) claim[@"birth"] = [[NSUUID UUID] UUIDString];
		claim[@"bodySHA256"] = MetadataHash(body);
		if ([action isEqual:@"intent"]) claim[@"kind"] = @"delete";
		NSData *data = [NSPropertyListSerialization dataWithPropertyList:claim format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
		if ([action isEqual:@"intent"])
			ok = data && CoordinatedWrite([root URLByAppendingPathComponent:@"intent.plist"], data, &error);
		else ok = data && body && CoordinatedSafeReplaceWithBackupPerformingAccessorAction(url, body,
			nil, 0, nil, names[@"sync"], data, &error) != nil;
	} else {
		Report(@"FAIL", @"AV-BIND-action", @"unknown action"); return 1;
	}
	Report(ok ? @"PASS" : @"FAIL", [@"AV-BIND-" stringByAppendingString:action], ErrorCode(error));
	return ok ? 0 : 1;
}
