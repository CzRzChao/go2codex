#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
source "$script_dir/lib/safety.sh"

user_home="$(current_user_home)"
installed_app="$user_home/Applications/Go2Codex.app"
system_app="/Applications/Go2Codex.app"
debug_app="$user_home/Applications/Go2CodexDebug.app"
build_root="$project_dir/.build"
derived_data="$build_root/release-candidate-derived"
product_app="$derived_data/Build/Products/Release/Go2Codex.app"
build_log="$build_root/release-candidate.log"
signing_config="$project_dir/Config/LocalSigning.conf"
local_state_root="$project_dir/.finder-toolbar-local"
candidate_root="$local_state_root/release-candidate"
candidate_app="$candidate_root/Go2Codex.app"
candidate_manifest="$candidate_root/manifest.env"
candidate_manifest_next="$candidate_root/manifest.env.next"
smoke_manifest="$local_state_root/debug-smoke.pass"
smoke_pending_manifest="$local_state_root/debug-smoke.pending"
smoke_pending_manifest_next="$local_state_root/debug-smoke.pending.next"
smoke_manifest_next="$local_state_root/debug-smoke.pass.next"
release_guard=""
candidate_complete=0
candidate_owned=0

assert_exact_path "$installed_app" "$user_home/Applications/Go2Codex.app" "Personal Release path"
[[ ! -e "$system_app" && ! -L "$system_app" ]] || safety_die "a second system-wide Go2Codex.app exists; Release identity is ambiguous"
ensure_fixed_project_directory "$build_root" "$project_dir/.build" "project build directory"
assert_no_symlink_components "$derived_data" "Release candidate DerivedData"
assert_no_symlink_components "$build_log" "Release candidate build log"
assert_no_symlink_components "$candidate_manifest" "Release candidate manifest"
assert_no_symlink_components "$candidate_manifest_next" "Release candidate manifest staging file"
assert_no_symlink_components "$smoke_pending_manifest" "Debug smoke pending record"
assert_no_symlink_components "$smoke_pending_manifest_next" "Debug smoke pending staging file"
assert_no_symlink_components "$smoke_manifest_next" "Debug smoke pass staging file"

cleanup() {
    local status="$1"
    local cleanup_failed=0
    trap - EXIT
    trap '' INT TERM
    set +e
    if [[ "${GO2CODEX_OPERATION_LOCK_ACTIVE:-0}" == "1" ]]; then
        if ! (cleanup_build_registrations "$derived_data" Release); then
            cleanup_failed=1
        fi
        if ! (cleanup_all_project_build_registrations "$project_dir"); then
            cleanup_failed=1
        fi
        if [[ "$candidate_owned" == "1" ]] && ! (unregister_exact_app_paths "$candidate_app"); then
            cleanup_failed=1
        fi
        if ! (remove_fixed_build_directory "$derived_data" "$project_dir" release-candidate-derived "Release candidate DerivedData"); then
            cleanup_failed=1
        fi
        if [[ "$candidate_owned" == "1" && "$candidate_complete" != "1" && -e "$candidate_root" ]]; then
            if [[ "$candidate_root" == "$project_dir/.finder-toolbar-local/release-candidate" && ! -L "$candidate_root" ]]; then
                /bin/rm -rf -- "$candidate_root" || cleanup_failed=1
            else
                cleanup_failed=1
            fi
        fi
        if ! (assert_no_project_build_registration "$project_dir"); then
            cleanup_failed=1
        fi
        if [[ -n "$release_guard" ]] && ! (assert_release_guard_unchanged "$release_guard"); then
            cleanup_failed=1
        fi
        release_operation_lock || cleanup_failed=1
    fi
    if [[ -n "$release_guard" ]]; then
        /bin/rm -f "$release_guard" || cleanup_failed=1
    fi
    if [[ "$cleanup_failed" != "0" && "$status" == "0" ]]; then
        status=1
    fi
    exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

release_guard="$(mktemp "/private/tmp/go2codex-candidate-release-guard.XXXXXX")" \
    || safety_die "Release guard could not be created"
create_release_guard "$release_guard" || safety_die "Release guard could not be initialized"

acquire_operation_lock "$project_dir" product
assert_no_unfinished_release_operation "$user_home" "$project_dir"
assert_paths_absent \
    "unfinished Debug smoke check" \
    "$smoke_pending_manifest" \
    "$smoke_pending_manifest_next" \
    "$smoke_manifest_next"

require_clean_git "$project_dir"
"$script_dir/verify-iterm-handoff.sh"
current_head="$(git_head "$project_dir")"
require_apple_development_identity "$signing_config"

assert_manifest_keys \
    "$smoke_manifest" \
    FORMAT_VERSION \
    GIT_HEAD \
    DEBUG_TREE_SHA256 \
    TEAM_ID \
    OUTER_REQUIREMENT_SHA256 \
    INNER_REQUIREMENT_SHA256 \
    CHECKLIST_VERSION \
    RESULT \
    RECORDED_AT
smoke_format="$(manifest_value "$smoke_manifest" FORMAT_VERSION)" || safety_die "Debug smoke format is unavailable"
smoke_head="$(manifest_value "$smoke_manifest" GIT_HEAD)" || safety_die "Debug smoke commit is unavailable"
smoke_result="$(manifest_value "$smoke_manifest" RESULT)" || safety_die "Debug smoke result is unavailable"
smoke_checklist="$(manifest_value "$smoke_manifest" CHECKLIST_VERSION)" || safety_die "Debug smoke checklist is unavailable"
smoke_team="$(manifest_value "$smoke_manifest" TEAM_ID)" || safety_die "Debug smoke signing team is unavailable"
smoke_outer_requirement="$(manifest_value "$smoke_manifest" OUTER_REQUIREMENT_SHA256)" || safety_die "Debug smoke outer signing requirement is unavailable"
smoke_inner_requirement="$(manifest_value "$smoke_manifest" INNER_REQUIREMENT_SHA256)" || safety_die "Debug smoke Launcher signing requirement is unavailable"
smoke_debug_tree="$(manifest_value "$smoke_manifest" DEBUG_TREE_SHA256)" || safety_die "Debug smoke tree is unavailable"
[[ "$smoke_format" == "1" ]] || safety_die "unsupported Debug smoke receipt"
[[ "$smoke_head" == "$current_head" ]] || safety_die "Debug smoke check does not match the current commit"
[[ "$smoke_result" == "pass" ]] || safety_die "Debug smoke check did not pass"
[[ "$smoke_checklist" == "4" ]] || safety_die "Debug smoke checklist is obsolete"
"$script_dir/verify-app.sh" "$debug_app" Debug --signing stable-local
debug_team="$(team_identifier "$debug_app")" || safety_die "installed Debug signing team is unavailable"
debug_outer_requirement="$(designated_requirement_hash "$debug_app")" || safety_die "installed Debug outer signing requirement is unavailable"
debug_inner_requirement="$(designated_requirement_hash "$debug_app/Contents/Helpers/Go2CodexLauncher.app")" || safety_die "installed Debug Launcher signing requirement is unavailable"
debug_tree="$(tree_fingerprint "$debug_app")" || safety_die "installed Debug fingerprint failed"
[[ -n "$debug_team" && "$debug_team" == "$GO2CODEX_SIGNING_TEAM_ID" ]] \
    || safety_die "installed Debug and Release candidate must use the same signing team"
[[ "$smoke_team" == "$GO2CODEX_SIGNING_TEAM_ID" ]] \
    || safety_die "Debug smoke check used a different signing team"
[[ "$smoke_outer_requirement" == "$debug_outer_requirement" ]] \
    || safety_die "Debug outer signing identity changed after the passing smoke check"
[[ "$smoke_inner_requirement" == "$debug_inner_requirement" ]] \
    || safety_die "Debug Launcher signing identity changed after the passing smoke check"
[[ "$smoke_debug_tree" == "$debug_tree" ]] \
    || safety_die "installed Debug changed after the passing smoke check"

marketing_version="$(xcconfig_value "$project_dir/Config/Base.xcconfig" MARKETING_VERSION)"
build_version="$(xcconfig_value "$project_dir/Config/Base.xcconfig" CURRENT_PROJECT_VERSION)"
[[ "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || safety_die "marketing version must use numeric major.minor.patch form"
assert_positive_integer "$build_version" "candidate build number"
installed_build=""
if [[ -e "$installed_app" ]]; then
    [[ -d "$installed_app" && ! -L "$installed_app" ]] || safety_die "installed Personal Release is unsafe"
    installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_app/Contents/Info.plist")"
fi
assert_newer_build_number "$build_version" "$installed_build"

GO2CODEX_NESTED_PRODUCT_LOCK_OWNER="$$" "$script_dir/test.sh"
require_clean_git "$project_dir"
cleanup_build_registrations "$derived_data" Release
cleanup_all_project_build_registrations "$project_dir"
prepare_regular_output_path "$build_log" "Release candidate build log"

/usr/bin/xcodebuild clean build \
    -project "$project_dir/Go2Codex.xcodeproj" \
    -scheme Go2Codex \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    "CODE_SIGN_STYLE=Manual" \
    "DEVELOPMENT_TEAM=$GO2CODEX_SIGNING_TEAM_ID" \
    "CODE_SIGN_IDENTITY=$GO2CODEX_SIGNING_IDENTITY_SHA1" \
    | /usr/bin/tee "$build_log"

cleanup_build_registrations "$derived_data" Release
cleanup_all_project_build_registrations "$project_dir"
assert_no_project_build_registration "$project_dir"
"$script_dir/verify-app.sh" "$product_app" Release --signing stable-local
[[ "$(team_identifier "$product_app")" == "$GO2CODEX_SIGNING_TEAM_ID" ]] || safety_die "Release product was signed by the wrong team"

if [[ ! -e "$local_state_root" ]]; then
    /bin/mkdir "$local_state_root"
fi
[[ -d "$local_state_root" && ! -L "$local_state_root" ]] || safety_die "local state directory is unsafe"
candidate_owned=1
if [[ -e "$candidate_root" ]]; then
    [[ -d "$candidate_root" && ! -L "$candidate_root" ]] || safety_die "candidate directory is unsafe"
    /bin/rm -rf -- "$candidate_root"
fi
/bin/mkdir "$candidate_root"
/usr/bin/ditto "$product_app" "$candidate_app"
"$script_dir/verify-app.sh" "$candidate_app" Release --signing stable-local
candidate_tree="$(tree_fingerprint "$candidate_app")" || safety_die "candidate fingerprint failed"
product_tree="$(tree_fingerprint "$product_app")" || safety_die "Release product fingerprint failed"
[[ "$candidate_tree" == "$product_tree" ]] || safety_die "candidate copy differs from the verified build product"
unregister_exact_app_paths "$candidate_app" \
    || safety_die "Release candidate remained registered with Launch Services"

candidate_outer_requirement="$(designated_requirement_hash "$candidate_app")" || safety_die "candidate outer signing requirement could not be recorded"
candidate_inner_requirement="$(designated_requirement_hash "$candidate_app/Contents/Helpers/Go2CodexLauncher.app")" || safety_die "candidate Launcher signing requirement could not be recorded"
smoke_receipt_sha="$(/usr/bin/shasum -a 256 "$smoke_manifest" | /usr/bin/awk '{ print $1 }')" || safety_die "Debug smoke receipt checksum could not be recorded"
created_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || safety_die "candidate creation time could not be recorded"
prepare_regular_output_path "$candidate_manifest_next" "Release candidate manifest staging file"
assert_safe_regular_output_path "$candidate_manifest" "Release candidate manifest"
/usr/bin/printf \
    'FORMAT_VERSION=1\nGIT_HEAD=%s\nMARKETING_VERSION=%s\nBUILD_VERSION=%s\nAPP_NAME=Go2Codex.app\nSIGNING_MODE=stable-local\nTEAM_ID=%s\nTREE_SHA256=%s\nOUTER_REQUIREMENT_SHA256=%s\nINNER_REQUIREMENT_SHA256=%s\nSMOKE_RECEIPT_SHA256=%s\nCREATED_AT=%s\n' \
    "$current_head" \
    "$marketing_version" \
    "$build_version" \
    "$GO2CODEX_SIGNING_TEAM_ID" \
    "$candidate_tree" \
    "$candidate_outer_requirement" \
    "$candidate_inner_requirement" \
    "$smoke_receipt_sha" \
    "$created_at" \
    >"$candidate_manifest_next" \
    || safety_die "Release candidate manifest could not be written"
atomic_replace_regular_file "$candidate_manifest_next" "$candidate_manifest" "Release candidate manifest" \
    || safety_die "Release candidate manifest could not be committed"

candidate_complete=1
assert_release_guard_unchanged "$release_guard"
echo "build-personal: verified Release candidate created without installing or launching it"
echo "$candidate_app"
