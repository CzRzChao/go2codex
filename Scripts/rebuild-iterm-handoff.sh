#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
source "$script_dir/lib/safety.sh"

if [[ $# -ne 1 || "$1" != "--confirm-rebuild-iterm-handoff" ]]; then
    echo "Usage: $0 --confirm-rebuild-iterm-handoff" >&2
    exit 64
fi

resource_dir="$project_dir/Sources/Go2CodexLauncher/Resources"
source_path="$resource_dir/ITermHandoff.applescript"
compiled_path="$resource_dir/ITermHandoff.scpt"
provenance_path="$resource_dir/ITermHandoff.provenance"
next_compiled="$resource_dir/ITermHandoff.scpt.next"
next_provenance="$resource_dir/ITermHandoff.provenance.next"
rebuild_root=""

cleanup() {
    local status="$1"
    local cleanup_failed=0
    trap - EXIT
    trap '' INT TERM
    if [[ -n "$rebuild_root" ]]; then
        if [[ -d "$rebuild_root" && ! -L "$rebuild_root" \
            && "$rebuild_root" == /private/tmp/go2codex-iterm-handoff.* ]]; then
            /bin/rm -rf -- "$rebuild_root" || cleanup_failed=1
        else
            cleanup_failed=1
        fi
    fi
    /bin/rm -f "$next_compiled" "$next_provenance" || cleanup_failed=1
    if [[ "$cleanup_failed" != "0" && "$status" == "0" ]]; then
        status=1
    fi
    exit "$status"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

assert_no_symlink_components "$source_path" "iTerm handoff source"
[[ -f "$source_path" && ! -L "$source_path" ]] \
    || safety_die "iTerm handoff source is missing or unsafe"
assert_safe_regular_output_path "$compiled_path" "iTerm handoff compiled resource"
assert_safe_regular_output_path "$provenance_path" "iTerm handoff provenance"
prepare_regular_output_path "$next_compiled" "next iTerm handoff compiled resource"
prepare_regular_output_path "$next_provenance" "next iTerm handoff provenance"

rebuild_root="$(mktemp -d "/private/tmp/go2codex-iterm-handoff.XXXXXX")" \
    || safety_die "temporary iTerm handoff rebuild directory could not be created"
staged_source="$rebuild_root/ITermHandoff.applescript"
staged_compiled="$rebuild_root/ITermHandoff.scpt"
staged_provenance="$rebuild_root/ITermHandoff.provenance"
decompiled_path="$rebuild_root/ITermHandoff.decompiled.applescript"
/bin/cp "$source_path" "$staged_source" \
    || safety_die "iTerm handoff source could not be staged"
source_sha="$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{ print $1 }')" \
    || safety_die "iTerm handoff source checksum could not be calculated"
[[ "$(/usr/bin/shasum -a 256 "$staged_source" | /usr/bin/awk '{ print $1 }')" == "$source_sha" ]] \
    || safety_die "staged iTerm handoff source differs from the repository source"
if /usr/bin/grep -E '(^|[[:space:]])close([[:space:]]|$)' "$staged_source" >/dev/null; then
    safety_die "iTerm handoff source must not close a session after an uncertain failure"
fi

/usr/bin/osacompile -o "$staged_compiled" "$staged_source" \
    || safety_die "iTerm handoff AppleScript compilation failed"
[[ -f "$staged_compiled" && ! -L "$staged_compiled" ]] \
    || safety_die "iTerm handoff compiler did not create a safe resource"
[[ "$(/usr/bin/file -b "$staged_compiled")" == "AppleScript compiled" ]] \
    || safety_die "iTerm handoff compiler produced an unexpected file type"
/usr/bin/osadecompile "$staged_compiled" >"$decompiled_path" \
    || safety_die "iTerm handoff compiled resource could not be decompiled"

decompiled_count() {
    local text="$1"
    /usr/bin/grep -F -c -- "$text" "$decompiled_path" || true
}

[[ "$(decompiled_count 'on go2codexNewWindow(commandText)')" == "1" ]] \
    || safety_die "compiled iTerm handoff is missing the exact new-window handler"
[[ "$(decompiled_count 'on go2codexNewTab(commandText)')" == "1" ]] \
    || safety_die "compiled iTerm handoff is missing the exact new-tab handler"
[[ "$(decompiled_count 'with timeout of 60 seconds')" == "2" ]] \
    || safety_die "compiled iTerm handoff must contain two 60-second timeouts"
[[ "$(decompiled_count 'return true')" == "2" ]] \
    || safety_die "compiled iTerm handoff must contain two explicit success results"
if /usr/bin/grep -E '(^|[[:space:]])close([[:space:]]|$)|coreclos' "$decompiled_path" >/dev/null; then
    safety_die "compiled iTerm handoff must not close a session after an uncertain failure"
fi
[[ "$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{ print $1 }')" == "$source_sha" ]] \
    || safety_die "iTerm handoff compilation changed the repository source"
compiled_sha="$(/usr/bin/shasum -a 256 "$staged_compiled" | /usr/bin/awk '{ print $1 }')" \
    || safety_die "iTerm handoff compiled checksum could not be calculated"
{
    /usr/bin/printf 'FORMAT_VERSION=1\n'
    /usr/bin/printf 'SOURCE_SHA256=%s\n' "$source_sha"
    /usr/bin/printf 'COMPILED_SHA256=%s\n' "$compiled_sha"
} >"$staged_provenance" \
    || safety_die "iTerm handoff provenance could not be staged"

"$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$staged_source" \
    "$staged_compiled" \
    "$staged_provenance" \
    >/dev/null
/bin/cp "$staged_compiled" "$next_compiled" \
    || safety_die "verified iTerm handoff compiled resource could not be staged for commit"
/bin/cp "$staged_provenance" "$next_provenance" \
    || safety_die "verified iTerm handoff provenance could not be staged for commit"
"$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$source_path" \
    "$next_compiled" \
    "$next_provenance" \
    >/dev/null
atomic_replace_regular_file \
    "$next_compiled" \
    "$compiled_path" \
    "iTerm handoff compiled resource" \
    || safety_die "iTerm handoff compiled resource could not be committed"
atomic_replace_regular_file \
    "$next_provenance" \
    "$provenance_path" \
    "iTerm handoff provenance" \
    || safety_die "iTerm handoff provenance could not be committed"

"$script_dir/verify-iterm-handoff.sh"
echo "rebuild-iterm-handoff: decompiled review output follows"
/bin/cat "$decompiled_path"
