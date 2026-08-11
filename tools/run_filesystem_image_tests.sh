#!/bin/zsh

set -u

test_binary=${1:-/tmp/notation-integration-tests/NVIntegrationTest}
if [[ ! -x "$test_binary" ]]; then
	print -u2 "missing integration-test executable: $test_binary"
	exit 2
fi

temp_base=${TMPDIR:-/tmp}
temp_base=${temp_base%/}
test_root=$(mktemp -d "$temp_base/notation-filesystem-images.XXXXXX") || exit 2
attached_device=""
failures=0

cleanup() {
	if [[ -n "$attached_device" ]]; then
		hdiutil detach "$attached_device" >/dev/null 2>&1 ||
			hdiutil detach -force "$attached_device" >/dev/null 2>&1 || true
	fi
	case "$test_root" in
		"$temp_base"/notation-filesystem-images.*) /bin/rm -rf -- "$test_root" ;;
	esac
}
trap cleanup EXIT INT TERM

attach_image() {
	local image=$1 mount_point=$2 output
	mkdir -p "$mount_point" || return 1
	output=$(hdiutil attach -owners off -nobrowse -noautoopen -mountpoint "$mount_point" "$image") || return 1
	attached_device=$(print -r -- "$output" | awk 'NR == 1 { print $1 }')
	[[ "$attached_device" == /dev/disk* ]]
}

detach_image() {
	[[ -n "$attached_device" ]] || return 0
	hdiutil detach "$attached_device" || return 1
	attached_device=""
}

force_detach_image() {
	[[ -n "$attached_device" ]] || return 0
	hdiutil detach -force "$attached_device" || return 1
	attached_device=""
}

detach_image_or_force() {
	detach_image || force_detach_image
}

run_test() {
	local label=$1 root=$2 fs_type=$3 case_sensitive=$4 scenario=$5
	print "TEST  $label / $scenario"
	if env NV_TEST_VOLUME_ROOT="$root" NV_EXPECT_FSTYPE="$fs_type" \
		NV_EXPECT_CASE_SENSITIVE="$case_sensitive" NV_TEST_REQUIRE_DISK_IMAGE=1 \
		"$test_binary" "$scenario"; then
		print "PASS  $label / $scenario"
	else
		print -u2 "FAIL  $label / $scenario"
		failures=$((failures + 1))
	fi
}

run_observation() {
	local label=$1 root=$2 fs_type=$3 case_sensitive=$4 scenario=$5
	print "TEST  $label / $scenario (open contract)"
	if env NV_TEST_VOLUME_ROOT="$root" NV_EXPECT_FSTYPE="$fs_type" \
		NV_EXPECT_CASE_SENSITIVE="$case_sensitive" NV_TEST_REQUIRE_DISK_IMAGE=1 \
		"$test_binary" "$scenario"; then
		print "PASS  $label / $scenario"
	else
		print "XFAIL $label / $scenario"
	fi
}

create_image() {
	local label=$1 filesystem=$2
	local image="$test_root/$label.sparseimage"
	hdiutil create -quiet -size 192m -type SPARSE -fs "$filesystem" -volname "$label" "$image" || return 1
	print -r -- "$image"
}

run_native_matrix() {
	local label=$1 filesystem=$2 fs_type=$3 case_sensitive=$4
	local image mount_point
	image=$(create_image "$label" "$filesystem") || return 1
	mount_point="$test_root/mnt-$label"
	attach_image "$image" "$mount_point" || return 1
	run_test "$label" "$mount_point" "$fs_type" "$case_sensitive" filesystem-capabilities
	run_test "$label" "$mount_point" "$fs_type" "$case_sensitive" filesystem-crud
	if [[ "$fs_type" != exfat ]]; then
		run_test "$label" "$mount_point" "$fs_type" "$case_sensitive" file-metadata
		run_test "$label" "$mount_point" "$fs_type" "$case_sensitive" directory-reconciliation
		if [[ "$fs_type" == hfs ]]; then
			run_observation "$label" "$mount_point" "$fs_type" "$case_sensitive" coarse-ctime-observation
		fi
		run_test "$label" "$mount_point" "$fs_type" "$case_sensitive" snapshot-stress
	fi
	if ! detach_image_or_force; then
		return 1
	fi
}

print "Fixed-size filesystem image matrix: $test_root"

apfs_image=$(create_image NVAPFS APFS) || exit 1
apfs_mount="$test_root/mnt-NVAPFS"
attach_image "$apfs_image" "$apfs_mount" || exit 1
run_test NVAPFS "$apfs_mount" apfs 0 filesystem-capabilities
run_test NVAPFS "$apfs_mount" apfs 0 filesystem-crud
run_test NVAPFS "$apfs_mount" apfs 0 system-tag-producer
run_test NVAPFS "$apfs_mount" apfs 0 wal-crash-recovery
run_test NVAPFS "$apfs_mount" apfs 0 disk-full-recovery-contract

bookmark_file="$test_root/remount.bookmark"
bookmark_directory="$apfs_mount/Bookmark Notes"
print "TEST  NVAPFS / bookmark-create"
if env NV_BOOKMARK_DIRECTORY="$bookmark_directory" NV_BOOKMARK_FILE="$bookmark_file" \
	"$test_binary" bookmark-create; then
	print "PASS  NVAPFS / bookmark-create"
else
	print -u2 "FAIL  NVAPFS / bookmark-create"
	failures=$((failures + 1))
fi
detach_image_or_force || exit 1
apfs_remount="$test_root/remount-NVAPFS"
attach_image "$apfs_image" "$apfs_remount" || exit 1
print "TEST  NVAPFS / bookmark-resolve after detach/remount"
if env NV_BOOKMARK_FILE="$bookmark_file" "$test_binary" bookmark-resolve; then
	print "PASS  NVAPFS / bookmark-resolve after detach/remount"
else
	print -u2 "FAIL  NVAPFS / bookmark-resolve after detach/remount"
	failures=$((failures + 1))
fi
detach_image_or_force || exit 1

live_mount="$test_root/live-NVAPFS"
attach_image "$apfs_image" "$live_mount" || exit 1
live_ready="$test_root/live-detach.ready"
live_continue="$test_root/live-detach.continue"
live_bookmark="$test_root/live-detach.bookmark"
live_directory="$live_mount/Live Detach Notes"
print "TEST  NVAPFS / live forced detach with open controller descriptors"
env NV_LIVE_DETACH_DIRECTORY="$live_directory" NV_BOOKMARK_FILE="$live_bookmark" \
	NV_LIVE_DETACH_READY="$live_ready" NV_LIVE_DETACH_CONTINUE="$live_continue" \
	"$test_binary" live-detach-child &
live_child=$!
for attempt in {1..300}; do
	[[ -e "$live_ready" ]] && break
	sleep 0.1
done
if [[ ! -e "$live_ready" ]]; then
	print -u2 "FAIL  NVAPFS / live detach child did not become ready"
	kill "$live_child" >/dev/null 2>&1 || true
	wait "$live_child" >/dev/null 2>&1 || true
	failures=$((failures + 1))
	detach_image_or_force || true
elif ! force_detach_image; then
	print -u2 "FAIL  NVAPFS / force detach"
	kill "$live_child" >/dev/null 2>&1 || true
	wait "$live_child" >/dev/null 2>&1 || true
	failures=$((failures + 1))
	detach_image_or_force || true
else
	touch "$live_continue"
	if wait "$live_child"; then
		print "PASS  NVAPFS / detached operations preserve in-memory state"
	else
		print -u2 "FAIL  NVAPFS / detached controller child"
		failures=$((failures + 1))
	fi
	live_remount="$test_root/live-remount-NVAPFS"
	if attach_image "$apfs_image" "$live_remount" &&
		env NV_BOOKMARK_FILE="$live_bookmark" \
		NV_BOOKMARK_EXPECTED_CONTENT="bookmark survives remount" \
		"$test_binary" bookmark-resolve; then
		print "PASS  NVAPFS / live-detach bookmark remount recovery"
	else
		print -u2 "FAIL  NVAPFS / live-detach bookmark remount recovery"
		failures=$((failures + 1))
	fi
	detach_image_or_force || failures=$((failures + 1))
fi

run_native_matrix NVAPFSX "Case-sensitive APFS" apfs 1 || failures=$((failures + 1))
run_native_matrix NVHFSJ "Journaled HFS+" hfs 0 || failures=$((failures + 1))
run_native_matrix NVHFSX "Case-sensitive Journaled HFS+" hfs 1 || failures=$((failures + 1))
run_native_matrix NVEXFAT ExFAT exfat 0 || failures=$((failures + 1))

print "Image-only residuals: SMB/NFS server semantics and real iCloud/Finder process coordination."
if (( failures )); then
	print -u2 "$failures filesystem image test(s) failed"
	exit 1
fi
print "All required filesystem image tests passed"
