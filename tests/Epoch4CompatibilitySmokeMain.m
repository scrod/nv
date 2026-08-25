/*
 * Historical reader entry point used only by test-epoch4-v5-compatibility.sh.
 * It is copied over main.m in a temporary checkout of the last epoch-4
 * sources, so the historical classes can load a database written by the
 * current sources without requiring a GUI or a checked-in database fixture.
 */

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import "NotationController.h"
#import "NotationPrefs.h"
#import "NoteObject.h"
#import "PassphraseRetriever.h"

#if EPOC_ITERATION != 4
#error This smoke reader must be built from the epoch-4 checkout.
#endif

static BOOL warningWasShown = NO;
static BOOL unexpectedAlertWasShown = NO;
static Method alertRunModalMethod = NULL;
static Method smokeRunModalMethod = NULL;
static BOOL alertMethodsSwizzled = NO;
static IMP originalPassphraseRetrieverImplementation = NULL;
static BOOL passphraseWasRequested = NO;

static NSString *SmokeNewerDatabaseMessage(void) {
	return NSLocalizedString(@"Warning: this database was created by a newer version of Notational Velocity. Continue anyway?", nil);
}

static NSInteger SmokeRunModal(NSAlert *alert, SEL selector) {
	(void)selector;
	NSString *message = [alert messageText];
	if ([message isEqualToString:SmokeNewerDatabaseMessage()]) {
		warningWasShown = YES;
		fprintf(stderr, "EPOCH4_COMPATIBILITY_WARNING_SHOWN\n");
		return NSAlertSecondButtonReturn;
	}
	/* Do not allow an unrelated startup alert to block the headless smoke
	 * test.  Record it so the test still fails instead of accepting it. */
	unexpectedAlertWasShown = YES;
	fprintf(stderr, "Unexpected alert during compatibility loading: %s\n",
		message ? [message UTF8String] : "<no message>");
	return NSAlertSecondButtonReturn;
}

static BOOL InstallAlertSwizzle(void) {
	alertRunModalMethod = class_getInstanceMethod([NSAlert class], @selector(runModal));
	if (!alertRunModalMethod) return NO;
	SEL smokeSelector = sel_registerName("nv_epoch4CompatibilitySmokeRunModal");
	if (!class_addMethod([NSAlert class], smokeSelector, (IMP)SmokeRunModal,
		method_getTypeEncoding(alertRunModalMethod)))
		return NO;
	smokeRunModalMethod = class_getInstanceMethod([NSAlert class], smokeSelector);
	if (!smokeRunModalMethod) return NO;
	method_exchangeImplementations(alertRunModalMethod, smokeRunModalMethod);
	alertMethodsSwizzled = YES;
	return YES;
}

static void RestoreAlertSwizzle(void) {
	if (alertMethodsSwizzled) {
		method_exchangeImplementations(alertRunModalMethod, smokeRunModalMethod);
		alertMethodsSwizzled = NO;
	}
}

static int SmokeLoadedUserPassphraseData(PassphraseRetriever *retriever, SEL selector) {
	(void)selector;
	passphraseWasRequested = YES;
	Ivar prefsIvar = class_getInstanceVariable([PassphraseRetriever class], "notationPrefs");
	NotationPrefs *prefs = object_getIvar(retriever, prefsIvar);
	NSData *passphrase = [@"integration-test-passphrase" dataUsingEncoding:NSUTF8StringEncoding];
	return [prefs canLoadPassphraseData:passphrase] ? 1 : 0;
}

static BOOL InstallPassphraseRetrieverSwizzle(void) {
	Method method = class_getInstanceMethod([PassphraseRetriever class],
		@selector(loadedUserPassphraseData));
	if (!method) return NO;
	originalPassphraseRetrieverImplementation = method_getImplementation(method);
	method_setImplementation(method, (IMP)SmokeLoadedUserPassphraseData);
	return YES;
}

static void RestorePassphraseRetrieverSwizzle(void) {
	if (originalPassphraseRetrieverImplementation) {
		Method method = class_getInstanceMethod([PassphraseRetriever class],
			@selector(loadedUserPassphraseData));
		method_setImplementation(method, originalPassphraseRetrieverImplementation);
		originalPassphraseRetrieverImplementation = NULL;
	}
}

static int Fail(const char *message, OSStatus status) {
	fprintf(stderr, "epoch-4 compatibility smoke test: %s (status %d)\n",
		message, (int)status);
	return 1;
}

int main(int argc, const char *argv[]) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	int result = 1;
	NotationController *controller = nil;

	if (argc != 2) {
		fprintf(stderr, "usage: %s NOTES_DIRECTORY\n", argv[0]);
		goto done;
	}

	FSRef directoryRef;
	Boolean isDirectory = false;
	OSStatus status = FSPathMakeRef((const UInt8*)argv[1], &directoryRef, &isDirectory);
	if (status != noErr || !isDirectory) {
		result = Fail("unable to open notes directory", status);
		goto done;
	}

	/* The real executable enters through NSApplicationMain before the
	 * controller is initialized.  Create that same application object so
	 * NSAlert can build its normal button response while runModal is swizzled. */
	[NSApplication sharedApplication];
	if (!InstallAlertSwizzle()) {
		result = Fail("unable to swizzle NSAlert runModal", paramErr);
		goto done;
	}
	if (!InstallPassphraseRetrieverSwizzle()) {
		result = Fail("unable to swizzle passphrase retrieval", paramErr);
		goto done;
	}

	controller = [[NotationController alloc] initWithDirectoryRef:&directoryRef error:&status];
	RestoreAlertSwizzle();
	RestorePassphraseRetrieverSwizzle();
	if (!controller) {
		result = Fail("historical controller could not load Notes & Settings", status);
		goto done;
	}

	NSArray *notes = [controller valueForKey:@"allNotes"];
	if ([notes count] != 1) {
		result = Fail("historical controller loaded an unexpected note count", noErr);
		goto done;
	}
	NoteObject *note = [notes objectAtIndex:0];
	NSString *title = titleOfNote(note);
	NSString *body = [[note contentString] string];
	NSString *labels = labelsOfNote(note);
	if (![title isEqualToString:@"Epoch Five Compatibility"] ||
		![body isEqualToString:@"epoch five compatibility body"] ||
		[labels rangeOfString:@"critical"].location == NSNotFound ||
		[labels rangeOfString:@"epoch5"].location == NSNotFound) {
		result = Fail("historical controller did not preserve critical note content", noErr);
		goto done;
	}
	if (createdDateOfNote(note) != 123456789.125 ||
		modifiedDateOfNote(note) != 123456999.875 ||
		![filenameOfNote(note) isEqualToString:@"epoch-five-compatibility.txt"] ||
		!NSEqualRanges(note->selectedRange, NSMakeRange(6, 4)) ||
		storageFormatOfNote(note) != SingleDatabaseFormat ||
		fileEncodingOfNote(note) != NSISOLatin1StringEncoding) {
		fprintf(stderr, "metadata: created=%.17g modified=%.17g filename=%s range={%lu,%lu} format=%d encoding=%lu\n",
			createdDateOfNote(note), modifiedDateOfNote(note),
			[filenameOfNote(note) UTF8String], (unsigned long)note->selectedRange.location,
			(unsigned long)note->selectedRange.length, storageFormatOfNote(note),
			(unsigned long)fileEncodingOfNote(note));
		result = Fail("historical controller did not preserve note metadata", noErr);
		goto done;
	}
	if (!warningWasShown) {
		result = Fail("historical controller did not report the newer database warning", noErr);
		goto done;
	}
	if (unexpectedAlertWasShown) {
		result = Fail("historical controller showed an unexpected alert", noErr);
		goto done;
	}
	if (!passphraseWasRequested || ![[controller notationPrefs] doesEncryption]) {
		result = Fail("historical controller did not decode the encrypted database", noErr);
		goto done;
	}

	fprintf(stdout, "epoch-4 compatibility smoke test loaded title=%s\n",
		[title UTF8String]);
	result = 0;

done:
	RestoreAlertSwizzle();
	RestorePassphraseRetrieverSwizzle();
	if (controller) {
		[controller closeAllResources];
		[controller release];
	}
	[pool drain];
	return result;
}
