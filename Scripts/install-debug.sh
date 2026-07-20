#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
source "$script_dir/lib/safety.sh"
source "$script_dir/lib/overlay-transaction.sh"

if ! debug_signing_mode="$(debug_install_signing_mode "$@")"; then
    echo "Usage: $0 --confirm-install-debug" >&2
    echo "       $0 --confirm-install-adhoc-debug" >&2
    exit 64
fi

user_home="$(current_user_home)"
applications_dir="$user_home/Applications"
target_app="$applications_dir/Go2CodexDebug.app"
transaction_root="$applications_dir/.go2codex-debug-update"
transaction_cleanup_root="$transaction_root.debug-install.cleanup"
transaction_preparing_root="$transaction_root.debug-install.preparing"
build_root="$project_dir/.build"
derived_data="$build_root/debug-install-derived"
product_app="$derived_data/Build/Products/Debug/Go2CodexDebug.app"
build_log="$build_root/debug-install.log"
signing_config="$project_dir/Config/LocalSigning.conf"
local_state_root="$project_dir/.finder-toolbar-local"
backup_root="$local_state_root/debug-backups"
stable_install_manifest="$local_state_root/debug-install.manifest"
adhoc_install_manifest="$local_state_root/debug-adhoc-install.manifest"
if [[ "$debug_signing_mode" == "stable-local" ]]; then
    install_manifest="$stable_install_manifest"
    obsolete_install_manifest="$adhoc_install_manifest"
else
    install_manifest="$adhoc_install_manifest"
    obsolete_install_manifest="$stable_install_manifest"
fi
install_manifest_next="$install_manifest.next"
release_guard=""
debug_expected_tree=""
debug_previous_expected_tree=""
backup_verification_root=""
debug_transaction_owned=0

[[ -d "$applications_dir" && ! -L "$applications_dir" ]] || safety_die "the user Applications directory is missing or unsafe"
assert_exact_path "$target_app" "$user_home/Applications/Go2CodexDebug.app" "Debug installation path"
assert_exact_path "$transaction_root" "$user_home/Applications/.go2codex-debug-update" "Debug transaction path"
assert_no_symlink_components "$transaction_cleanup_root" "retired Debug transaction"
assert_no_symlink_components "$transaction_preparing_root" "Debug transaction preparation"
ensure_fixed_project_directory "$build_root" "$project_dir/.build" "project build directory"
assert_no_symlink_components "$derived_data" "Debug DerivedData"
assert_no_symlink_components "$build_log" "Debug build log"
assert_no_symlink_components "$stable_install_manifest" "stable Debug installation record"
assert_no_symlink_components "$adhoc_install_manifest" "temporary ad-hoc Debug installation record"
assert_no_symlink_components "$install_manifest" "Debug installation record"
assert_no_symlink_components "$install_manifest_next" "Debug installation record staging file"

debug_verify_callback() {
    local installed="$1"
    local staged="$2"
    local installed_tree
    local staged_tree
    "$script_dir/verify-app.sh" "$installed" Debug --signing "$debug_signing_mode" || return 1
    installed_tree="$(tree_fingerprint "$installed")" || return 1
    staged_tree="$(tree_fingerprint "$staged")" || return 1
    [[ "$installed_tree" == "$staged_tree" ]] || return 1
    [[ -n "$debug_expected_tree" && "$installed_tree" == "$debug_expected_tree" ]] || return 1
    return 0
}

debug_register_callback() {
    register_exact_app "$1" || return 1
    return 0
}

debug_recovery_callback() {
    local restored="$1"
    local had_previous="$2"
    if [[ "$had_previous" == "true" ]]; then
        local restored_mode
        local restored_marketing
        local restored_build
        local restored_tree
        local expected_previous_tree="$debug_previous_expected_tree"
        restored_mode="$(signature_mode "$restored")" || return 1
        restored_marketing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$restored/Contents/Info.plist")" || return 1
        restored_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$restored/Contents/Info.plist")" || return 1
        restored_tree="$(tree_fingerprint "$restored")" || return 1
        if [[ -z "$expected_previous_tree" && -f "$install_manifest" && ! -L "$install_manifest" ]]; then
            expected_previous_tree="$(manifest_value "$install_manifest" TREE_SHA256)" || return 1
        fi
        if [[ -n "$expected_previous_tree" ]]; then
            [[ "$restored_tree" == "$expected_previous_tree" ]] || return 1
        fi
        "$script_dir/verify-app.sh" \
            "$restored" \
            Debug \
            --signing "$restored_mode" \
            --content compatible \
            --marketing-version "$restored_marketing" \
            --build-version "$restored_build" \
            || return 1
        register_exact_app "$restored" || return 1
    else
        [[ ! -e "$restored" && ! -L "$restored" ]] || return 1
        unregister_exact_app_paths "$restored" || return 1
    fi
    return 0
}

cleanup() {
    local status="$1"
    local cleanup_failed=0
    trap - EXIT
    trap '' INT TERM
    set +e
    if [[ "${GO2CODEX_OPERATION_LOCK_ACTIVE:-0}" == "1" ]]; then
        if ! (cleanup_build_registrations "$derived_data" Debug); then
            cleanup_failed=1
        fi
        if ! (cleanup_all_project_build_registrations "$project_dir"); then
            cleanup_failed=1
        fi
        if ! (remove_fixed_build_directory "$derived_data" "$project_dir" debug-install-derived "Debug DerivedData"); then
            cleanup_failed=1
        fi
        if [[ "$debug_transaction_owned" == "1" && -d "$transaction_root" && -f "$transaction_root/state" ]]; then
            if ! (recover_overlay_transaction "$target_app" "$transaction_root" debug-install debug_recovery_callback); then
                cleanup_failed=1
            else
                cleanup_failed=1
            fi
        fi
        if [[ "$debug_transaction_owned" == "1" && ( -e "$transaction_cleanup_root" || -L "$transaction_cleanup_root" ) ]] \
            && [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]]; then
            if ! (finalize_retired_overlay_transaction "$transaction_root" debug-install); then
                cleanup_failed=1
            fi
        fi
        if [[ -n "$backup_verification_root" && -d "$backup_verification_root" && "$backup_verification_root" == "$local_state_root"/debug-backup-check.* ]]; then
            /bin/rm -rf -- "$backup_verification_root" || cleanup_failed=1
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

release_guard="$(mktemp "/private/tmp/go2codex-debug-release-guard.XXXXXX")" \
    || safety_die "Release guard could not be created"
create_release_guard "$release_guard" || safety_die "Release guard could not be initialized"

acquire_operation_lock "$project_dir" product
assert_no_unfinished_release_operation "$user_home" "$project_dir"

if [[ -e "$transaction_preparing_root" || -L "$transaction_preparing_root" ]]; then
    [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] \
        || safety_die "Debug preparation and active transaction evidence conflict"
    [[ ! -e "$transaction_cleanup_root" && ! -L "$transaction_cleanup_root" ]] \
        || safety_die "Debug preparation and retired transaction evidence conflict"
    [[ -d "$transaction_preparing_root" && ! -L "$transaction_preparing_root" ]] \
        || safety_die "an unsafe Debug transaction preparation requires manual inspection"
    debug_transaction_owned=1
    discard_abandoned_overlay_preparation "$transaction_root" debug-install \
        || safety_die "the abandoned Debug transaction preparation could not be cleared safely"
    safety_die "an interrupted Debug transaction preparation was cleared before any app change; run the Debug installation again"
fi

if [[ -e "$transaction_cleanup_root" || -L "$transaction_cleanup_root" ]]; then
    [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] \
        || safety_die "Debug transaction and retired cleanup evidence conflict"
    [[ -d "$transaction_cleanup_root" && ! -L "$transaction_cleanup_root" ]] \
        || safety_die "an unsafe retired Debug transaction requires manual inspection"
    debug_transaction_owned=1
    finalize_retired_overlay_transaction "$transaction_root" debug-install \
        || safety_die "the retired Debug transaction could not be cleared safely"
    safety_die "an interrupted Debug transaction cleanup was cleared; run the Debug installation again"
fi

if [[ -e "$transaction_root" ]]; then
    [[ -d "$transaction_root" && ! -L "$transaction_root" && -f "$transaction_root/state" ]] \
        || safety_die "an invalid Debug update transaction requires manual inspection"
    transaction_operation_matches "$transaction_root" debug-install \
        || safety_die "the Debug transaction belongs to another or unknown operation"
    debug_transaction_owned=1
    recover_overlay_transaction "$target_app" "$transaction_root" debug-install debug_recovery_callback
    safety_die "the interrupted Debug update was recovered; run the command again"
fi

GO2CODEX_NESTED_PRODUCT_LOCK_OWNER="$$" "$script_dir/test.sh"
build_signing_arguments=()
if [[ "$debug_signing_mode" == "stable-local" ]]; then
    require_apple_development_identity "$signing_config"
    build_signing_arguments=(
        "CODE_SIGN_STYLE=Manual"
        "DEVELOPMENT_TEAM=$GO2CODEX_SIGNING_TEAM_ID"
        "CODE_SIGN_IDENTITY=$GO2CODEX_SIGNING_IDENTITY_SHA1"
    )
else
    build_signing_arguments=(
        "CODE_SIGN_STYLE=Manual"
        "DEVELOPMENT_TEAM="
        "CODE_SIGN_IDENTITY=-"
    )
fi
cleanup_build_registrations "$derived_data" Debug
cleanup_all_project_build_registrations "$project_dir"
prepare_regular_output_path "$build_log" "Debug build log"

/usr/bin/xcodebuild clean build \
    -project "$project_dir/Go2Codex.xcodeproj" \
    -scheme Go2Codex \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    "${build_signing_arguments[@]}" \
    | /usr/bin/tee "$build_log"

cleanup_build_registrations "$derived_data" Debug
cleanup_all_project_build_registrations "$project_dir"
assert_no_project_build_registration "$project_dir"
"$script_dir/verify-app.sh" "$product_app" Debug --signing "$debug_signing_mode"
if [[ "$debug_signing_mode" == "stable-local" ]]; then
    [[ "$(team_identifier "$product_app")" == "$GO2CODEX_SIGNING_TEAM_ID" ]] || safety_die "Debug product was signed by the wrong team"
fi
debug_expected_tree="$(tree_fingerprint "$product_app")" || safety_die "Debug product fingerprint failed"

if [[ -e "$target_app" ]]; then
    installed_signing_mode="$(signature_mode "$target_app")" || safety_die "installed Debug signing mode is unavailable"
    assert_debug_signing_transition "$debug_signing_mode" "$installed_signing_mode"
    installed_marketing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target_app/Contents/Info.plist")"
    installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target_app/Contents/Info.plist")"
    "$script_dir/verify-app.sh" \
        "$target_app" \
        Debug \
        --signing "$installed_signing_mode" \
        --content compatible \
        --marketing-version "$installed_marketing" \
        --build-version "$installed_build"
    if [[ "$debug_signing_mode" == "stable-local" && "$installed_signing_mode" == "stable-local" ]]; then
        installed_outer_requirement="$(designated_requirement_hash "$target_app")" || safety_die "installed Debug outer signing requirement is unavailable"
        product_outer_requirement="$(designated_requirement_hash "$product_app")" || safety_die "Debug product outer signing requirement is unavailable"
        [[ "$installed_outer_requirement" == "$product_outer_requirement" ]] \
            || safety_die "Debug outer signing identity changed"
        installed_inner="$target_app/Contents/Applications/Go2CodexLauncher.app"
        product_inner="$product_app/Contents/Applications/Go2CodexLauncher.app"
        installed_inner_requirement="$(designated_requirement_hash "$installed_inner")" || safety_die "installed Debug Launcher signing requirement is unavailable"
        product_inner_requirement="$(designated_requirement_hash "$product_inner")" || safety_die "Debug product Launcher signing requirement is unavailable"
        [[ "$installed_inner_requirement" == "$product_inner_requirement" ]] \
            || safety_die "Debug Launcher signing identity changed"
    fi
    debug_previous_expected_tree="$(tree_fingerprint "$target_app")" || safety_die "installed Debug fingerprint failed"
fi

terminate_exact_app_processes \
    "$target_app/Contents/MacOS/Go2CodexDebug" \
    "$target_app/Contents/Applications/Go2CodexLauncher.app/Contents/MacOS/Go2CodexLauncher"

if [[ ! -e "$local_state_root" ]]; then
    /bin/mkdir "$local_state_root"
fi
[[ -d "$local_state_root" && ! -L "$local_state_root" ]] || safety_die "local state directory is unsafe"
if [[ ! -e "$backup_root" ]]; then
    /bin/mkdir "$backup_root"
fi
[[ -d "$backup_root" && ! -L "$backup_root" ]] || safety_die "Debug backup directory is unsafe"

prepare_overlay_transaction "$product_app" "$target_app" "$transaction_root" debug-install
debug_transaction_owned=1
if [[ "$(transaction_state_value "$transaction_root" HAD_PREVIOUS)" == "1" ]]; then
    backup_path="$backup_root/Go2CodexDebug-$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$$.zip"
    [[ "$backup_path" != *.app ]] || safety_die "Debug backup path must not end in .app"
    assert_no_symlink_components "$backup_path" "Debug backup path"
    [[ ! -e "$backup_path" && ! -L "$backup_path" ]] || safety_die "Debug backup path already exists"
    /usr/bin/ditto -c -k --keepParent "$transaction_root/previous.payload" "$backup_path"
    /usr/bin/unzip -tq "$backup_path" >/dev/null
    debug_previous_tree="$(transaction_state_value "$transaction_root" PREVIOUS_TREE_SHA256)" || safety_die "Debug previous snapshot fingerprint is unavailable"
    backup_verification_root="$(mktemp -d "$local_state_root/debug-backup-check.XXXXXX")" || safety_die "Debug backup verification directory could not be created"
    /usr/bin/ditto -x -k "$backup_path" "$backup_verification_root" || safety_die "Debug backup could not be extracted for verification"
    debug_backup_payload="$backup_verification_root/previous.payload"
    debug_backup_source="$backup_verification_root/Go2CodexDebug.app"
    rename_extracted_app_for_verification \
        "$debug_backup_payload" \
        "$debug_backup_source" \
        Go2CodexDebug.app \
        "Debug backup verification"
    debug_backup_top_level_count="$(/usr/bin/find "$backup_verification_root" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
        || safety_die "Debug backup contents could not be enumerated"
    [[ "$debug_backup_top_level_count" == "1" ]] || safety_die "Debug backup contains unexpected top-level entries"
    debug_backup_tree="$(tree_fingerprint "$debug_backup_source")" || safety_die "Debug backup fingerprint failed"
    [[ "$debug_backup_tree" == "$debug_previous_tree" ]] || safety_die "Debug backup differs from the installed snapshot"
    debug_backup_marketing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$debug_backup_source/Contents/Info.plist")" || safety_die "Debug backup marketing version is unavailable"
    debug_backup_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$debug_backup_source/Contents/Info.plist")" || safety_die "Debug backup build version is unavailable"
    debug_backup_signing_mode="$(signature_mode "$debug_backup_source")" || safety_die "Debug backup signing mode is unavailable"
    "$script_dir/verify-app.sh" \
        "$debug_backup_source" \
        Debug \
        --signing "$debug_backup_signing_mode" \
        --content compatible \
        --marketing-version "$debug_backup_marketing" \
        --build-version "$debug_backup_build"
    /bin/rm -rf -- "$backup_verification_root" || safety_die "Debug backup verification directory could not be removed"
    backup_verification_root=""
fi

unset GO2CODEX_TRANSACTION_FAIL_STAGE || true
commit_overlay_transaction \
    "$target_app" \
    "$transaction_root" \
    debug-install \
    debug_verify_callback \
    debug_register_callback \
    debug_recovery_callback

installed_debug_tree="$(tree_fingerprint "$target_app")" || safety_die "installed Debug fingerprint failed"
[[ "$installed_debug_tree" == "$debug_expected_tree" ]] || safety_die "installed Debug changed after transaction verification"
if ! head_value="$(/usr/bin/git -C "$project_dir" rev-parse --verify HEAD 2>/dev/null)"; then
    head_value="NONE"
fi
git_status="$(/usr/bin/git -C "$project_dir" status --porcelain --untracked-files=all)" || safety_die "Git status could not be read for the Debug installation record"
if [[ -z "$git_status" && "$head_value" != "NONE" ]]; then
    worktree_clean=1
else
    worktree_clean=0
fi
if [[ "$debug_signing_mode" == "stable-local" ]]; then
    debug_outer_requirement="$(designated_requirement_hash "$target_app")" || safety_die "Debug outer signing requirement could not be recorded"
    debug_inner_requirement="$(designated_requirement_hash "$target_app/Contents/Applications/Go2CodexLauncher.app")" || safety_die "Debug Launcher signing requirement could not be recorded"
else
    debug_outer_requirement="NONE"
    debug_inner_requirement="NONE"
fi
prepare_regular_output_path "$install_manifest_next" "Debug installation record staging file"
assert_safe_regular_output_path "$install_manifest" "Debug installation record"
if [[ "$debug_signing_mode" == "stable-local" ]]; then
    /usr/bin/printf \
        'FORMAT_VERSION=1\nGIT_HEAD=%s\nWORKTREE_CLEAN=%s\nTREE_SHA256=%s\nTEAM_ID=%s\nOUTER_REQUIREMENT_SHA256=%s\nINNER_REQUIREMENT_SHA256=%s\n' \
        "$head_value" \
        "$worktree_clean" \
        "$debug_expected_tree" \
        "$GO2CODEX_SIGNING_TEAM_ID" \
        "$debug_outer_requirement" \
        "$debug_inner_requirement" \
        >"$install_manifest_next" \
        || safety_die "Debug installation record could not be written"
else
    /usr/bin/printf \
        'FORMAT_VERSION=1\nPURPOSE=temporary-observation\nGIT_HEAD=%s\nWORKTREE_CLEAN=%s\nTREE_SHA256=%s\nSIGNING_MODE=adhoc\nTEAM_ID=NONE\nOUTER_REQUIREMENT_SHA256=%s\nINNER_REQUIREMENT_SHA256=%s\n' \
        "$head_value" \
        "$worktree_clean" \
        "$debug_expected_tree" \
        "$debug_outer_requirement" \
        "$debug_inner_requirement" \
        >"$install_manifest_next" \
        || safety_die "temporary ad-hoc Debug installation record could not be written"
fi
atomic_replace_regular_file "$install_manifest_next" "$install_manifest" "Debug installation record" \
    || safety_die "Debug installation record could not be committed"
if [[ -e "$obsolete_install_manifest" ]]; then
    /bin/rm -f "$obsolete_install_manifest" || safety_die "obsolete Debug installation record could not be removed"
fi

assert_release_guard_unchanged "$release_guard"
if [[ "$debug_signing_mode" == "stable-local" ]]; then
    echo "install-debug: installed and registered the isolated stable-signed Debug app; nothing was launched and Release was unchanged"
else
    echo "install-debug: installed and registered the isolated temporary ad-hoc Debug app; nothing was launched, Release was unchanged, and this build cannot authorize smoke or promotion"
fi
