CLANG := clang
CFLAGS := -fno-objc-arc -mmacosx-version-min=11.5 -I..
BUILD_DIR := /tmp/notation-integration-tests
DERIVED_DATA := ../DerivedData
HOST_ARCH := $(shell uname -m)
APP_OBJECT_DIR := $(DERIVED_DATA)/Build/Intermediates.noindex/ArchiveIntermediates/Notation/IntermediateBuildFilesPath/Notation.build/Deployment/Notation.build/Objects-normal/$(HOST_ARCH)
APP_OBJECTS = $(shell find "$(APP_OBJECT_DIR)" -maxdepth 1 -name '*.o' ! -name main.o ! -name '*_vers.o')
NV_INTEGRATION_APP_OBJECTS = $(filter-out %/NVRootedDirectory.o,$(APP_OBJECTS))
APP_FRAMEWORKS := -F.. -Wl,-rpath,$(abspath ..) -Wl,-sectcreate,__TEXT,__info_plist,../Info.plist -framework Sparkle -framework Cocoa -framework Carbon -framework CoreServices -framework SecurityInterface -framework Security -framework WebKit -framework ApplicationServices -framework SystemConfiguration -framework IOKit -framework UniformTypeIdentifiers -lz
ICLOUD_API_TEST_ROOT ?= $(HOME)/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing
FILE_PROVIDER_API_TEST_ROOT ?= $(HOME)/Library/CloudStorage/Dropbox/API_Contract_Testing
ICLOUD_API_TEST_APP := $(BUILD_DIR)/ICloudAPIContractTest.app
TARGETS := \
	$(BUILD_DIR)/AppearanceColorTest \
	$(BUILD_DIR)/GlobalPrefsArchiveMigrationTest \
	$(BUILD_DIR)/ICloudAPIContractTest \
	$(BUILD_DIR)/ModernStickiesImportTest \
	$(BUILD_DIR)/WebArchiveImportIntegrationTest \
	$(BUILD_DIR)/NVIntegrationTest

.PHONY: all run run-core run-platform run-icloud-api-contract run-file-provider-api-contract \
	run-icloud-api-contract-remote-host run-icloud-api-contract-remote-peer \
	run-icloud-api-contract-legacy-upload run-icloud-api-contract-sync-control-probe \
	run-icloud-api-contract-pause-lifecycle \
	stress leak-check filesystem-image-stress clean app-objects

all: $(TARGETS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/GlobalPrefsArchiveMigrationTest: GlobalPrefsArchiveMigrationTest.m Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $< $(APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

$(BUILD_DIR)/AppearanceColorTest: AppearanceColorTest.m Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $< $(APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

$(BUILD_DIR)/ICloudAPIContractTest: ICloudAPIContractTest.m Makefile | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) -fblocks $< -framework Foundation -framework FileProvider -o $@

$(BUILD_DIR)/ICloudAPIContractTest-x86_64: ICloudAPIContractTest.m Makefile | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) -arch x86_64 -fblocks $< -framework Foundation -framework FileProvider -o $@

$(ICLOUD_API_TEST_APP): $(BUILD_DIR)/ICloudAPIContractTest ICloudAPIContractTest-Info.plist
	mkdir -p $@/Contents/MacOS
	cp $(BUILD_DIR)/ICloudAPIContractTest $@/Contents/MacOS/ICloudAPIContractTest
	cp ICloudAPIContractTest-Info.plist $@/Contents/Info.plist
	codesign --force --sign - --timestamp=none $@

app-objects:
	/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild install -project ../Notation.xcodeproj -scheme Notation -configuration Deployment -derivedDataPath $(DERIVED_DATA) -destination generic/platform=macOS CODE_SIGNING_ALLOWED=NO -quiet

$(BUILD_DIR)/ModernStickiesImportTest: ModernStickiesImportTest.m Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $< $(APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

$(BUILD_DIR)/WebArchiveImportIntegrationTest: WebArchiveImportIntegrationTest.m Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $< $(APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

$(BUILD_DIR)/NVIntegrationTest: NVIntegrationTest.m NVRootedDirectoryTestHooks.m \
	NVRootedDirectoryTestHooks.h \
	../NVRootedDirectory.m ../NVRootedDirectory.h ../NVRootedDirectory_Private.h Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) -DNV_INTEGRATION_TESTING=1 $< NVRootedDirectoryTestHooks.m \
		../NVRootedDirectory.m $(NV_INTEGRATION_APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

run: run-core run-platform

run-core: all
	$(BUILD_DIR)/AppearanceColorTest
	$(BUILD_DIR)/GlobalPrefsArchiveMigrationTest
	$(BUILD_DIR)/WebArchiveImportIntegrationTest
	$(BUILD_DIR)/NVIntegrationTest lifecycle
	$(BUILD_DIR)/NVIntegrationTest resource-lifecycle
	$(BUILD_DIR)/NVIntegrationTest bulk-parser
	$(BUILD_DIR)/NVIntegrationTest file-metadata
	$(BUILD_DIR)/NVIntegrationTest directory-reconciliation
	$(BUILD_DIR)/NVIntegrationTest snapshot-failures
	$(BUILD_DIR)/NVIntegrationTest snapshot-boundary-races
	$(BUILD_DIR)/NVIntegrationTest ambiguous-content
	$(BUILD_DIR)/NVIntegrationTest partial-bulk-fallback
	$(BUILD_DIR)/NVIntegrationTest scan-atomicity-contract
	$(BUILD_DIR)/NVIntegrationTest failed-scan-retry-contract
	$(BUILD_DIR)/NVIntegrationTest catalog-fence-contract
	$(BUILD_DIR)/NVIntegrationTest directory-fence-modes
	$(BUILD_DIR)/NVIntegrationTest unsaved-write-recovery-contract
	$(BUILD_DIR)/NVIntegrationTest external-editing-text-merge
	$(BUILD_DIR)/NVIntegrationTest epoch-five-archive
	$(BUILD_DIR)/NVIntegrationTest single-database
	$(BUILD_DIR)/NVIntegrationTest plain-text
	$(BUILD_DIR)/NVIntegrationTest storage-transition-memory-wins
	$(BUILD_DIR)/NVIntegrationTest open-files-workflow
	$(BUILD_DIR)/NVIntegrationTest deletion-contracts
	$(BUILD_DIR)/NVIntegrationTest storage-transitions
	$(BUILD_DIR)/NVIntegrationTest filename-collisions
	$(BUILD_DIR)/NVIntegrationTest concurrent-controllers
	$(BUILD_DIR)/NVIntegrationTest unsupported-journal-locks
	$(BUILD_DIR)/NVIntegrationTest legacy-temporary-database-recovery
	$(BUILD_DIR)/NVIntegrationTest wal-record-recovery
	$(BUILD_DIR)/NVIntegrationTest wal-recovery-workflows
	$(BUILD_DIR)/NVIntegrationTest wal-history-recovery
	$(BUILD_DIR)/NVIntegrationTest wal-damaged-tail-recovery
	$(BUILD_DIR)/NVIntegrationTest wal-recovery-retry-idempotence
	$(BUILD_DIR)/NVIntegrationTest wal-database-ordering
	$(BUILD_DIR)/NVIntegrationTest wal-durability-boundaries
	$(BUILD_DIR)/NVIntegrationTest plain-text-encodings
	$(BUILD_DIR)/NVIntegrationTest filesystem-crud
	$(BUILD_DIR)/NVIntegrationTest file-barrier-sync
	$(BUILD_DIR)/NVIntegrationTest rename-without-preflight
	$(BUILD_DIR)/NVIntegrationTest rename-enoent-source-proof
	$(BUILD_DIR)/NVIntegrationTest rtf
	$(BUILD_DIR)/NVIntegrationTest directory-identity
	$(BUILD_DIR)/NVIntegrationTest directory-relocation-races
	$(BUILD_DIR)/NVIntegrationTest location-migration
	$(BUILD_DIR)/NVIntegrationTest preferences-migration
	$(BUILD_DIR)/NVIntegrationTest deep-directory
	$(BUILD_DIR)/NVIntegrationTest atomic-rollback
	$(BUILD_DIR)/NVIntegrationTest reference-edges
	$(BUILD_DIR)/NVIntegrationTest legacy-fixtures
	$(BUILD_DIR)/NVIntegrationTest encryption
	$(BUILD_DIR)/NVIntegrationTest failures
	$(BUILD_DIR)/NVIntegrationTest file-outbox-crash-recovery

run-platform: all
	$(BUILD_DIR)/ModernStickiesImportTest
	$(BUILD_DIR)/NVIntegrationTest html
	$(BUILD_DIR)/NVIntegrationTest trash
	$(BUILD_DIR)/NVIntegrationTest fsevents-live

run-icloud-api-contract: $(ICLOUD_API_TEST_APP)
	rm -f $(BUILD_DIR)/ICloudAPIContractTest-icloud-stdout.txt $(BUILD_DIR)/ICloudAPIContractTest-icloud-stderr.txt
	open -n -W --stdout $(BUILD_DIR)/ICloudAPIContractTest-icloud-stdout.txt \
		--stderr $(BUILD_DIR)/ICloudAPIContractTest-icloud-stderr.txt $(ICLOUD_API_TEST_APP) \
		--args local "$(ICLOUD_API_TEST_ROOT)" required
	cat $(BUILD_DIR)/ICloudAPIContractTest-icloud-stdout.txt $(BUILD_DIR)/ICloudAPIContractTest-icloud-stderr.txt
	! grep -q '^FAIL ' $(BUILD_DIR)/ICloudAPIContractTest-icloud-stdout.txt

run-file-provider-api-contract: $(ICLOUD_API_TEST_APP)
	rm -f $(BUILD_DIR)/ICloudAPIContractTest-provider-stdout.txt $(BUILD_DIR)/ICloudAPIContractTest-provider-stderr.txt
	open -n -W --stdout $(BUILD_DIR)/ICloudAPIContractTest-provider-stdout.txt \
		--stderr $(BUILD_DIR)/ICloudAPIContractTest-provider-stderr.txt $(ICLOUD_API_TEST_APP) \
		--args local "$(FILE_PROVIDER_API_TEST_ROOT)" observe
	cat $(BUILD_DIR)/ICloudAPIContractTest-provider-stdout.txt $(BUILD_DIR)/ICloudAPIContractTest-provider-stderr.txt
	! grep -q '^FAIL ' $(BUILD_DIR)/ICloudAPIContractTest-provider-stdout.txt

run-icloud-api-contract-legacy-upload: $(BUILD_DIR)/ICloudAPIContractTest
	$(BUILD_DIR)/ICloudAPIContractTest legacy-upload "$(ICLOUD_API_TEST_ROOT)"

run-icloud-api-contract-sync-control-probe: $(ICLOUD_API_TEST_APP)
	rm -f $(BUILD_DIR)/ICloudAPIContractTest-app-stdout.txt $(BUILD_DIR)/ICloudAPIContractTest-app-stderr.txt
	open -n -W --stdout $(BUILD_DIR)/ICloudAPIContractTest-app-stdout.txt \
		--stderr $(BUILD_DIR)/ICloudAPIContractTest-app-stderr.txt $(ICLOUD_API_TEST_APP) \
		--args sync-control-probe "$(ICLOUD_API_TEST_ROOT)"
	cat $(BUILD_DIR)/ICloudAPIContractTest-app-stdout.txt $(BUILD_DIR)/ICloudAPIContractTest-app-stderr.txt
	! grep -q '^FAIL ' $(BUILD_DIR)/ICloudAPIContractTest-app-stdout.txt

run-icloud-api-contract-pause-lifecycle: $(ICLOUD_API_TEST_APP)
	rm -f $(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stderr.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stderr.txt
	open -n -W --stdout $(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stdout.txt \
		--stderr $(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stderr.txt $(ICLOUD_API_TEST_APP) \
		--args pause-lifecycle-prepare "$(ICLOUD_API_TEST_ROOT)"
	open -n -W --stdout $(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stdout.txt \
		--stderr $(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stderr.txt $(ICLOUD_API_TEST_APP) \
		--args pause-lifecycle-repair "$(ICLOUD_API_TEST_ROOT)"
	cat $(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stderr.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stderr.txt
	! grep -q '^FAIL ' $(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stdout.txt

run-icloud-api-contract-remote-host: $(BUILD_DIR)/ICloudAPIContractTest
	NV_ICLOUD_API_TEST_TIMEOUT=900 $(BUILD_DIR)/ICloudAPIContractTest remote-host "$(ICLOUD_API_TEST_ROOT)"

run-icloud-api-contract-remote-peer: $(BUILD_DIR)/ICloudAPIContractTest
	NV_ICLOUD_API_TEST_TIMEOUT=900 $(BUILD_DIR)/ICloudAPIContractTest remote-peer "$(ICLOUD_API_TEST_ROOT)"

stress: $(BUILD_DIR)/NVIntegrationTest
	$(BUILD_DIR)/NVIntegrationTest snapshot-stress
	$(BUILD_DIR)/NVIntegrationTest snapshot-boundary-races
	$(BUILD_DIR)/NVIntegrationTest snapshot-in-place-observation
	$(BUILD_DIR)/NVIntegrationTest bulk-parser-fuzz
	$(BUILD_DIR)/NVIntegrationTest partial-bulk-fallback
	$(BUILD_DIR)/NVIntegrationTest xattr-interoperability
	$(BUILD_DIR)/NVIntegrationTest ambiguity-stress

leak-check: $(BUILD_DIR)/NVIntegrationTest
	/usr/bin/leaks --quiet --atExit -- $(BUILD_DIR)/NVIntegrationTest resource-lifecycle

filesystem-image-stress: $(BUILD_DIR)/NVIntegrationTest
	../tools/run_filesystem_image_tests.sh $(BUILD_DIR)/NVIntegrationTest

clean:
	rm -f $(TARGETS) $(BUILD_DIR)/ICloudAPIContractTest-x86_64 \
		$(BUILD_DIR)/ICloudAPIContractTest-icloud-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-icloud-stderr.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-provider-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-provider-stderr.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-app-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-app-stderr.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-prepare-stderr.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stdout.txt \
		$(BUILD_DIR)/ICloudAPIContractTest-lifecycle-repair-stderr.txt
	rm -rf $(ICLOUD_API_TEST_APP)
