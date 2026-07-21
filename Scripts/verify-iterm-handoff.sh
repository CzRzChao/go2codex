#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
source "$script_dir/lib/safety.sh"

usage() {
    echo "Usage: $0" >&2
    echo "       $0 --files <source.applescript> <compiled.scpt> <provenance>" >&2
    exit 64
}

if [[ $# -eq 0 ]]; then
    resource_dir="$project_dir/Sources/Go2CodexLauncher/Resources"
    source_path="$resource_dir/ITermHandoff.applescript"
    compiled_path="$resource_dir/ITermHandoff.scpt"
    provenance_path="$resource_dir/ITermHandoff.provenance"
elif [[ $# -eq 4 && "$1" == "--files" ]]; then
    source_path="$2"
    compiled_path="$3"
    provenance_path="$4"
else
    usage
fi

assert_no_symlink_components "$source_path" "iTerm handoff source"
assert_no_symlink_components "$compiled_path" "iTerm handoff compiled resource"
assert_no_symlink_components "$provenance_path" "iTerm handoff provenance"
[[ -f "$source_path" && ! -L "$source_path" ]] \
    || safety_die "iTerm handoff source is missing or unsafe"
[[ -f "$compiled_path" && ! -L "$compiled_path" ]] \
    || safety_die "iTerm handoff compiled resource is missing or unsafe"
[[ -f "$provenance_path" && ! -L "$provenance_path" ]] \
    || safety_die "iTerm handoff provenance is missing or unsafe"

assert_manifest_keys \
    "$provenance_path" \
    FORMAT_VERSION \
    SOURCE_SHA256 \
    COMPILED_SHA256

format_version="$(manifest_value "$provenance_path" FORMAT_VERSION)"
expected_source_sha="$(manifest_value "$provenance_path" SOURCE_SHA256)"
expected_compiled_sha="$(manifest_value "$provenance_path" COMPILED_SHA256)"
[[ "$format_version" == "1" ]] \
    || safety_die "unsupported iTerm handoff provenance format"
[[ "$expected_source_sha" =~ ^[a-f0-9]{64}$ ]] \
    || safety_die "iTerm handoff source checksum is invalid"
[[ "$expected_compiled_sha" =~ ^[a-f0-9]{64}$ ]] \
    || safety_die "iTerm handoff compiled checksum is invalid"

actual_source_sha="$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{ print $1 }')" \
    || safety_die "iTerm handoff source checksum could not be calculated"
actual_compiled_sha="$(/usr/bin/shasum -a 256 "$compiled_path" | /usr/bin/awk '{ print $1 }')" \
    || safety_die "iTerm handoff compiled checksum could not be calculated"
[[ "$actual_source_sha" == "$expected_source_sha" ]] \
    || safety_die "iTerm handoff source does not match its provenance"
[[ "$actual_compiled_sha" == "$expected_compiled_sha" ]] \
    || safety_die "iTerm handoff compiled resource does not match its provenance"
[[ "$(/usr/bin/file -b "$compiled_path")" == "AppleScript compiled" ]] \
    || safety_die "iTerm handoff compiled resource has an unexpected file type"

echo "verify-iterm-handoff: source and compiled resource match their provenance"
