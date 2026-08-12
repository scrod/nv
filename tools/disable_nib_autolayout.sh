#!/bin/zsh

set -euo pipefail
setopt null_glob

script_name=${0:t}

usage() {
	print -u2 "usage: $script_name path/to/SomeView.nib"
	exit 2
}

(( $# == 1 )) || usage

script_dir=${0:A:h}
project_root=${script_dir:h}
project_file="$project_root/Notation.xcodeproj/project.pbxproj"

[[ -f "$project_file" ]] || {
	print -u2 "missing project file: $project_file"
	exit 2
}

deployment_targets=$(sed -nE 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET = "?([^";]+)"?;.*/\1/p' "$project_file" | sort -u)
deployment_target_count=$(print -r -- "$deployment_targets" | awk 'NF { count++ } END { print count + 0 }')
if (( deployment_target_count != 1 )); then
	print -u2 "expected one project MACOSX_DEPLOYMENT_TARGET, found:"
	print -u2 -r -- "$deployment_targets"
	exit 2
fi
deployment_target=$(print -r -- "$deployment_targets" | awk 'NF { print; exit }')

input_path=$1
[[ -e "$input_path" ]] || {
	print -u2 "nib does not exist: $input_path"
	exit 2
}

if [[ -d "$input_path" ]]; then
	nib_dir=${input_path:A}
elif [[ ${input_path:t} == designable.nib ]]; then
	nib_dir=${input_path:A:h}
else
	usage
fi

designable="$nib_dir/designable.nib"
[[ ${nib_dir:e} == nib && -f "$designable" ]] || {
	print -u2 "expected an editable nib package containing designable.nib: $nib_dir"
	exit 2
}

print -u2 "Warning: an open Xcode document can overwrite this result."

nib_temp_base=${TMPDIR:-/tmp}
nib_temp_base=${nib_temp_base%/}
nib_work_dir=$(mktemp -d "$nib_temp_base/notation-disable-nib-autolayout.XXXXXX")

cleanup() {
	case "$nib_work_dir" in
		"$nib_temp_base"/notation-disable-nib-autolayout.*) /bin/rm -rf -- "$nib_work_dir" ;;
	esac
}
trap cleanup EXIT INT TERM

run_ibtool() {
	local log=$1
	shift
	if ! xcrun ibtool "$@" >"$log" 2>&1; then
		tail -n 80 "$log" >&2
		exit 1
	fi
}

candidate="$nib_work_dir/${nib_dir:t}"
cp -R "$nib_dir" "$candidate"
candidate_designable="$candidate/designable.nib"

# Current ibtool cannot edit a file named designable.nib directly because it
# treats the extension as compiled. Upgrade old XML archives through a .xib.
if rg -q '<archive type="com.apple.InterfaceBuilder3.Cocoa.XIB"' "$candidate_designable"; then
	cp "$candidate_designable" "$nib_work_dir/input.xib"
	run_ibtool "$nib_work_dir/upgrade.log" --upgrade --write "$nib_work_dir/upgraded.xib" "$nib_work_dir/input.xib"
	cp "$nib_work_dir/upgraded.xib" "$candidate_designable"
fi

perl -0pi -e '
	s/ useAutolayout="[^"]*"//g;
	s/ translatesAutoresizingMaskIntoConstraints="[^"]*"//g;
	s/\n[ \t]*<constraints>\s*.*?<\/constraints>//sg;
	s{<deployment\b[^>]*/>}{<deployment identifier="macosx"/>}g;
' "$candidate_designable"

xmllint --noout "$candidate_designable"
if rg -q 'useAutolayout|translatesAutoresizingMaskIntoConstraints|<constraints>|<constraint[ >]' "$candidate_designable"; then
	print -u2 "failed to remove all Auto Layout metadata from $nib_dir"
	exit 1
fi
rg -q '<deployment identifier="macosx"/>' "$candidate_designable" || {
	print -u2 "failed to set the nib to inherit the project deployment target"
	exit 1
}

candidate_variants=("$candidate"/keyedobjects-*.nib)
(( ${#candidate_variants} == 0 )) || /bin/rm -- "${candidate_variants[@]}"

cp "$candidate_designable" "$nib_work_dir/compile.xib"
run_ibtool "$nib_work_dir/compile.log" --compile "$candidate/keyedobjects.nib" "$nib_work_dir/compile.xib" \
	--minimum-deployment-target "$deployment_target" --target-device mac

cp "$candidate_designable" "$designable"
cp "$candidate/keyedobjects.nib" "$nib_dir/keyedobjects.nib"

installed_variants=("$nib_dir"/keyedobjects-*.nib)
(( ${#installed_variants} == 0 )) || /bin/rm -- "${installed_variants[@]}"

print "Disabled Auto Layout: $nib_dir"
print "Deployment target: $deployment_target"
