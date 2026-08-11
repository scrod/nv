CLANG := clang
CFLAGS := -fno-objc-arc -mmacosx-version-min=11.5 -I..
BUILD_DIR := /tmp/notation-integration-tests
DERIVED_DATA := ../DerivedData
HOST_ARCH := $(shell uname -m)
APP_OBJECT_DIR := $(DERIVED_DATA)/Build/Intermediates.noindex/ArchiveIntermediates/Notation/IntermediateBuildFilesPath/Notation.build/Deployment/Notation.build/Objects-normal/$(HOST_ARCH)
APP_OBJECTS = $(filter-out $(APP_OBJECT_DIR)/main.o,$(wildcard $(APP_OBJECT_DIR)/*.o))
APP_FRAMEWORKS := -F.. -Wl,-rpath,$(abspath ..) -Wl,-sectcreate,__TEXT,__info_plist,../Info.plist -framework Sparkle -framework Cocoa -framework Carbon -framework CoreServices -framework SecurityInterface -framework Security -framework WebKit -framework ApplicationServices -framework SystemConfiguration -framework IOKit -framework UniformTypeIdentifiers -lz
TARGETS := \
	$(BUILD_DIR)/GlobalPrefsArchiveMigrationTest \
	$(BUILD_DIR)/ModernStickiesImportTest \
	$(BUILD_DIR)/WebArchiveImportIntegrationTest \
	$(BUILD_DIR)/NVIntegrationTest

.PHONY: all run run-core run-platform stress leak-check filesystem-image-stress clean app-objects

all: $(TARGETS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/GlobalPrefsArchiveMigrationTest: GlobalPrefsArchiveMigrationTest.m Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $< $(APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

app-objects:
	/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild install -project ../Notation.xcodeproj -scheme Notation -configuration Deployment -derivedDataPath $(DERIVED_DATA) -destination generic/platform=macOS CODE_SIGNING_ALLOWED=NO -quiet

$(BUILD_DIR)/ModernStickiesImportTest: ModernStickiesImportTest.m Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $< $(APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

$(BUILD_DIR)/WebArchiveImportIntegrationTest: WebArchiveImportIntegrationTest.m Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $< $(APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

$(BUILD_DIR)/NVIntegrationTest: NVIntegrationTest.m Makefile app-objects | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $< $(APP_OBJECTS) $(APP_FRAMEWORKS) -o $@

run: run-core run-platform

run-core: all
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
	$(BUILD_DIR)/NVIntegrationTest wal-history-recovery
	$(BUILD_DIR)/NVIntegrationTest wal-damaged-tail-recovery
	$(BUILD_DIR)/NVIntegrationTest wal-recovery-retry-idempotence
	$(BUILD_DIR)/NVIntegrationTest wal-database-ordering
	$(BUILD_DIR)/NVIntegrationTest wal-durability-boundaries
	$(BUILD_DIR)/NVIntegrationTest plain-text-encodings
	$(BUILD_DIR)/NVIntegrationTest filesystem-crud
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
	rm -f $(TARGETS)
