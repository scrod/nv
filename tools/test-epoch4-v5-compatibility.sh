#!/bin/zsh

# Standalone epoch-4 archive export/readability smoke test. Each run builds a
# historical reader, so it runs separately from the normal headless suite.
# The script name retains a development-era label; the compatibility boundary is
# epoch-4 Notes & Settings, the format used by the last public release in 2011.
set -euo pipefail

readonly repo_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly epoch4_commit="f4ada9d2e3c34fb816183bf9864074770605a4d3"
readonly work_root="$(mktemp -d "${TMPDIR:-/tmp}/nv-epoch4-v5.XXXXXX")"
readonly current_database="${work_root}/current-database"
readonly epoch4_checkout="${work_root}/epoch4"
readonly epoch4_derived_data="${work_root}/epoch4-derived-data"
readonly epoch4_build_log="${work_root}/epoch4-build.log"

cleanup() {
	rm -rf "$work_root"
}
trap cleanup EXIT

echo "Building the current database writer..."
make -C "$repo_root/tests" /tmp/notation-integration-tests/NVIntegrationTest
NV_EPOCH5_DATABASE_DIRECTORY="$current_database" \
	/tmp/notation-integration-tests/NVIntegrationTest \
	encryption

# The reader test is about the Notes & Settings archive, not WAL compatibility.
# A clean current shutdown normally retires this file; remove it if one is
# left behind so the epoch-4 process starts with exactly the generated archive.
current_journal="$current_database/Interim Note-Changes"
if [[ -e "$current_journal" ]]; then
	rm -f "$current_journal"
fi

mkdir -p "$epoch4_checkout"
git -C "$repo_root" archive "$epoch4_commit" | tar -x -C "$epoch4_checkout"
cp "$repo_root/tests/Epoch4CompatibilitySmokeMain.m" "$epoch4_checkout/main.m"

echo "Building the epoch-4 reader from $epoch4_commit..."
if ! /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
	-project "$epoch4_checkout/Notation.xcodeproj" \
	-scheme Notation \
	-configuration Deployment \
	-derivedDataPath "$epoch4_derived_data" \
	CODE_SIGNING_ALLOWED=NO \
	OTHER_LDFLAGS='$(inherited) -framework UniformTypeIdentifiers' \
	-quiet >"$epoch4_build_log" 2>&1; then
	cat "$epoch4_build_log" >&2
	exit 1
fi

reader="$(find "$epoch4_derived_data/Build/Products/Deployment" \
	-type f -path '*/Contents/MacOS/Notational Velocity' -print -quit)"
if [[ -z "$reader" ]]; then
	echo "epoch-4 compatibility smoke test: reader executable was not built" >&2
	exit 1
fi

reader_stderr="$work_root/reader.stderr"
reader_stdout="$work_root/reader.stdout"
if "$reader" "$current_database" >"$reader_stdout" 2>"$reader_stderr"; then
	reader_status=0
else
	reader_status=$?
	cat "$reader_stdout" "$reader_stderr" >&2
	echo "epoch-4 compatibility reader exited with status $reader_status" >&2
	exit "$reader_status"
fi
grep -F "EPOCH4_COMPATIBILITY_WARNING_SHOWN" \
	"$reader_stderr" >/dev/null
cat "$reader_stdout"
echo "Epoch-4 archive export/readability compatibility smoke test passed."
