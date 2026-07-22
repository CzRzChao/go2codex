#!/usr/bin/env bash

set -euo pipefail

install_mode=""
case "${1:-}" in
    --confirm-install) install_mode="normal" ;;
    --confirm-migrate-adhoc) install_mode="migrate" ;;
    *)
        echo "Usage: $0 --confirm-install" >&2
        echo "       $0 --confirm-migrate-adhoc" >&2
        exit 64
        ;;
esac
[[ $# -eq 1 ]] || {
    echo "install-personal: exactly one confirmation option is required" >&2
    exit 64
}

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
source "$script_dir/lib/safety.sh"
source "$script_dir/lib/overlay-transaction.sh"

user_home="$(current_user_home)"
applications_dir="$user_home/Applications"
target_app="$applications_dir/Go2Codex.app"
system_app="/Applications/Go2Codex.app"
transaction_root="$applications_dir/.go2codex-update"
local_state_root="$project_dir/.finder-toolbar-local"
candidate_root="$local_state_root/release-candidate"
candidate_app="$candidate_root/Go2Codex.app"
candidate_manifest="$candidate_root/manifest.env"
debug_app="$applications_dir/Go2CodexDebug.app"
smoke_manifest="$local_state_root/debug-smoke.pass"
smoke_pending_manifest="$local_state_root/debug-smoke.pending"
smoke_pending_manifest_next="$local_state_root/debug-smoke.pending.next"
smoke_manifest_next="$local_state_root/debug-smoke.pass.next"
backup_root="$local_state_root/backups"
pending_manifest="$local_state_root/install.pending"
pending_manifest_next="$local_state_root/install.pending.next"
last_install_manifest="$local_state_root/last-install.manifest"
rollback_pending_manifest="$local_state_root/rollback.pending"
rollback_pending_manifest_next="$local_state_root/rollback.pending.next"
rollback_receipt_next="$local_state_root/last-rollback.manifest.next"
install_preparing_root="$transaction_root.release-install.preparing"
rollback_preparing_root="$transaction_root.release-rollback.preparing"
install_cleanup_root="$transaction_root.release-install.cleanup"
rollback_cleanup_root="$transaction_root.release-rollback.cleanup"
legacy_preparing_root="$transaction_root.preparing"
install_complete=0
release_state_owned=0
backup_verification_root=""
candidate_marketing_version=""
candidate_build_version=""
expected_outer_inode=""
expected_inner_inode=""
candidate_expected_tree=""
expected_previous_release_tree=""
previous_inner_path="$target_app/Contents/Helpers/Go2CodexLauncher.app"

[[ -d "$applications_dir" && ! -L "$applications_dir" ]] || safety_die "the user Applications directory is missing or unsafe"
assert_exact_path "$target_app" "$user_home/Applications/Go2Codex.app" "Personal Release path"
assert_exact_path "$transaction_root" "$user_home/Applications/.go2codex-update" "Personal Release transaction path"
[[ ! -e "$system_app" && ! -L "$system_app" ]] || safety_die "a second system-wide Go2Codex.app exists; installation is ambiguous"
[[ -d "$local_state_root" && ! -L "$local_state_root" ]] || safety_die "local release state is missing or unsafe"
assert_no_symlink_components "$candidate_root" "Release candidate directory"
assert_no_symlink_components "$candidate_app" "Release candidate app"
assert_no_symlink_components "$candidate_manifest" "Release candidate manifest"
assert_no_symlink_components "$smoke_manifest" "Debug smoke pass record"
assert_no_symlink_components "$pending_manifest" "installation pending record"
assert_no_symlink_components "$pending_manifest_next" "installation pending staging file"
assert_no_symlink_components "$last_install_manifest" "last installation record"
assert_no_symlink_components "$rollback_pending_manifest" "rollback pending record"
assert_no_symlink_components "$rollback_pending_manifest_next" "rollback pending staging file"
assert_no_symlink_components "$rollback_receipt_next" "rollback receipt staging file"
assert_no_symlink_components "$install_preparing_root" "installation transaction preparation"
assert_no_symlink_components "$rollback_preparing_root" "rollback transaction preparation"
assert_no_symlink_components "$install_cleanup_root" "retired installation transaction"
assert_no_symlink_components "$rollback_cleanup_root" "retired rollback transaction"
assert_no_symlink_components "$legacy_preparing_root" "legacy transaction preparation"
assert_no_symlink_components "$smoke_pending_manifest" "Debug smoke pending record"
assert_no_symlink_components "$smoke_pending_manifest_next" "Debug smoke pending staging file"
assert_no_symlink_components "$smoke_manifest_next" "Debug smoke pass staging file"

install_foreign_release_evidence_exists() {
    local path

    for path in \
        "$rollback_pending_manifest" \
        "$rollback_pending_manifest_next" \
        "$rollback_receipt_next" \
        "$rollback_preparing_root" \
        "$rollback_cleanup_root" \
        "$legacy_preparing_root"; do
        if [[ -e "$path" || -L "$path" ]]; then
            return 0
        fi
    done
    return 1
}

release_verify_callback() {
    local installed="$1"
    local staged="$2"
    local installed_tree
    local staged_tree
    "$script_dir/verify-app.sh" \
        "$installed" \
        Release \
        --signing stable-local \
        --marketing-version "$candidate_marketing_version" \
        --build-version "$candidate_build_version" \
        || return 1
    installed_tree="$(tree_fingerprint "$installed")" || return 1
    staged_tree="$(tree_fingerprint "$staged")" || return 1
    [[ "$installed_tree" == "$staged_tree" ]] || return 1
    [[ -n "$candidate_expected_tree" && "$installed_tree" == "$candidate_expected_tree" ]] || return 1
    if [[ -n "$expected_outer_inode" ]]; then
        [[ "$(/usr/bin/stat -f '%i' "$installed")" == "$expected_outer_inode" ]] || return 1
    fi
    if [[ -n "$expected_inner_inode" ]]; then
        [[ "$(/usr/bin/stat -f '%i' "$installed/Contents/Helpers/Go2CodexLauncher.app")" == "$expected_inner_inode" ]] || return 1
    fi
    return 0
}

release_register_callback() {
    register_exact_app "$1" || return 1
    return 0
}

release_recovery_callback() {
    local restored="$1"
    local had_previous="$2"
    if [[ "$had_previous" == "true" ]]; then
        local previous_mode
        local previous_marketing
        local previous_build
        local previous_tree
        local restored_tree
        local expected_previous_tree="$expected_previous_release_tree"
        previous_mode="$(signature_mode "$restored")" || return 1
        previous_marketing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$restored/Contents/Info.plist")" || return 1
        previous_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$restored/Contents/Info.plist")" || return 1
        previous_tree="$(transaction_state_value "$transaction_root" PREVIOUS_TREE_SHA256)" || return 1
        restored_tree="$(tree_fingerprint "$restored")" || return 1
        [[ "$restored_tree" == "$previous_tree" ]] || return 1
        if [[ -f "$pending_manifest" && ! -L "$pending_manifest" ]]; then
            expected_previous_tree="$(manifest_value "$pending_manifest" PREVIOUS_TREE_SHA256)" || return 1
        fi
        if [[ -n "$expected_previous_tree" && "$expected_previous_tree" != "absent" ]]; then
            [[ "$restored_tree" == "$expected_previous_tree" ]] || return 1
        fi
        "$script_dir/verify-app.sh" \
            "$restored" \
            Release \
            --signing "$previous_mode" \
            --content compatible \
            --marketing-version "$previous_marketing" \
            --build-version "$previous_build" \
            || return 1
        register_exact_app "$restored" || return 1
    else
        [[ ! -e "$restored" && ! -L "$restored" ]] || return 1
        unregister_exact_app_paths "$restored" || return 1
    fi
    return 0
}

validate_install_pending_record() {
    local format
    local head
    local new_tree
    local new_marketing
    local new_build
    local previous_tree
    local previous_mode
    local previous_marketing
    local previous_build
    local backup_file
    local backup_sha
    local migration

    assert_manifest_keys \
        "$pending_manifest" \
        FORMAT_VERSION \
        GIT_HEAD \
        NEW_TREE_SHA256 \
        NEW_MARKETING_VERSION \
        NEW_BUILD_VERSION \
        PREVIOUS_TREE_SHA256 \
        PREVIOUS_SIGNING_MODE \
        PREVIOUS_MARKETING_VERSION \
        PREVIOUS_BUILD_VERSION \
        BACKUP_FILE \
        BACKUP_SHA256 \
        MIGRATION \
        || return 1
    format="$(manifest_value "$pending_manifest" FORMAT_VERSION)" || return 1
    head="$(manifest_value "$pending_manifest" GIT_HEAD)" || return 1
    new_tree="$(manifest_value "$pending_manifest" NEW_TREE_SHA256)" || return 1
    new_marketing="$(manifest_value "$pending_manifest" NEW_MARKETING_VERSION)" || return 1
    new_build="$(manifest_value "$pending_manifest" NEW_BUILD_VERSION)" || return 1
    previous_tree="$(manifest_value "$pending_manifest" PREVIOUS_TREE_SHA256)" || return 1
    previous_mode="$(manifest_value "$pending_manifest" PREVIOUS_SIGNING_MODE)" || return 1
    previous_marketing="$(manifest_value "$pending_manifest" PREVIOUS_MARKETING_VERSION)" || return 1
    previous_build="$(manifest_value "$pending_manifest" PREVIOUS_BUILD_VERSION)" || return 1
    backup_file="$(manifest_value "$pending_manifest" BACKUP_FILE)" || return 1
    backup_sha="$(manifest_value "$pending_manifest" BACKUP_SHA256)" || return 1
    migration="$(manifest_value "$pending_manifest" MIGRATION)" || return 1

    [[ "$format" == "1" ]] || return 1
    [[ "$head" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || return 1
    [[ "$new_tree" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$new_marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$new_build" =~ ^[1-9][0-9]*$ ]] || return 1
    case "$migration" in
        0|1) ;;
        *) return 1 ;;
    esac
    if [[ "$previous_tree" == "absent" ]]; then
        [[ "$previous_mode" == "NONE" ]] || return 1
        [[ "$previous_marketing" == "NONE" && "$previous_build" == "NONE" ]] || return 1
        [[ "$backup_file" == "NONE" && "$backup_sha" == "NONE" ]] || return 1
        [[ "$migration" == "0" ]] || return 1
    else
        [[ "$previous_tree" =~ ^[a-f0-9]{64}$ ]] || return 1
        case "$previous_mode" in
            adhoc) [[ "$migration" == "1" ]] || return 1 ;;
            stable-local) [[ "$migration" == "0" ]] || return 1 ;;
            *) return 1 ;;
        esac
        [[ "$previous_marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        [[ "$previous_build" =~ ^[1-9][0-9]*$ ]] || return 1
        [[ "$backup_file" != */* && "$backup_file" == *.zip ]] || return 1
        [[ "$backup_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
    fi
    return 0
}

validate_install_transaction_evidence() {
    local phase
    local transaction_previous
    local transaction_next
    local pending_previous
    local pending_next

    transaction_operation_matches "$transaction_root" release-install || return 1
    validate_transaction_payloads "$transaction_root" false || return 1
    phase="$(transaction_state_value "$transaction_root" PHASE)" || return 1
    if [[ ! -e "$pending_manifest" && ! -L "$pending_manifest" ]]; then
        [[ "$phase" == "prepared" ]] || return 1
        return 0
    fi
    [[ -f "$pending_manifest" && ! -L "$pending_manifest" ]] || return 1
    validate_install_pending_record || return 1
    transaction_previous="$(transaction_state_value "$transaction_root" PREVIOUS_TREE_SHA256)" || return 1
    transaction_next="$(transaction_state_value "$transaction_root" NEXT_TREE_SHA256)" || return 1
    pending_previous="$(manifest_value "$pending_manifest" PREVIOUS_TREE_SHA256)" || return 1
    pending_next="$(manifest_value "$pending_manifest" NEW_TREE_SHA256)" || return 1
    [[ "$transaction_previous" == "$pending_previous" ]] || return 1
    [[ "$transaction_next" == "$pending_next" ]] || return 1
    return 0
}

reconcile_pending_install() {
    if [[ ! -e "$pending_manifest" && ! -L "$pending_manifest" ]]; then
        return 0
    fi
    [[ -f "$pending_manifest" && ! -L "$pending_manifest" ]] || return 1
    validate_install_pending_record || return 1

    local pending_format
    local pending_new_tree
    local pending_new_marketing
    local pending_new_build
    local pending_previous_tree
    local actual_tree=""
    pending_format="$(manifest_value "$pending_manifest" FORMAT_VERSION)" || return 1
    pending_new_tree="$(manifest_value "$pending_manifest" NEW_TREE_SHA256)" || return 1
    pending_new_marketing="$(manifest_value "$pending_manifest" NEW_MARKETING_VERSION)" || return 1
    pending_new_build="$(manifest_value "$pending_manifest" NEW_BUILD_VERSION)" || return 1
    pending_previous_tree="$(manifest_value "$pending_manifest" PREVIOUS_TREE_SHA256)" || return 1
    [[ "$pending_format" == "1" ]] || return 1

    if [[ -d "$target_app" && ! -L "$target_app" ]]; then
        actual_tree="$(tree_fingerprint "$target_app")" || return 1
    fi
    if [[ -n "$actual_tree" && "$actual_tree" == "$pending_new_tree" ]]; then
        "$script_dir/verify-app.sh" \
            "$target_app" \
            Release \
            --signing stable-local \
            --content compatible \
            --marketing-version "$pending_new_marketing" \
            --build-version "$pending_new_build" \
            || return 1
        atomic_replace_regular_file "$pending_manifest" "$last_install_manifest" "last installation record" || return 1
        return 0
    fi

    if [[ "$pending_previous_tree" == "absent" && ! -e "$target_app" && ! -L "$target_app" ]]; then
        /bin/rm -f "$pending_manifest" || return 1
        return 0
    fi
    if [[ -n "$actual_tree" && "$actual_tree" == "$pending_previous_tree" ]]; then
        /bin/rm -f "$pending_manifest" || return 1
        return 0
    fi

    echo "install-personal: pending installation does not match the installed or previous verified tree; preserving its records" >&2
    return 1
}

cleanup() {
    local status="$1"
    local cleanup_failed=0
    trap - EXIT
    trap '' INT TERM
    set +e
    if [[ "${GO2CODEX_OPERATION_LOCK_ACTIVE:-0}" == "1" ]]; then
        if [[ "$release_state_owned" == "1" && -d "$transaction_root" && -f "$transaction_root/state" ]] \
            && ! install_foreign_release_evidence_exists; then
            if (validate_install_transaction_evidence); then
                if ! (recover_overlay_transaction "$target_app" "$transaction_root" release-install release_recovery_callback); then
                    cleanup_failed=1
                else
                    cleanup_failed=1
                fi
            else
                cleanup_failed=1
            fi
        fi
        if [[ "$release_state_owned" == "1" && "$install_complete" != "1" && ( -e "$pending_manifest" || -L "$pending_manifest" ) && ! -e "$transaction_root" ]] \
            && ! install_foreign_release_evidence_exists; then
            if ! (reconcile_pending_install); then
                cleanup_failed=1
            fi
        fi
        if [[ "$release_state_owned" == "1" && ( -e "$install_cleanup_root" || -L "$install_cleanup_root" ) && ! -e "$transaction_root" ]] \
            && ! install_foreign_release_evidence_exists; then
            if [[ ! -e "$pending_manifest" && ! -L "$pending_manifest" ]]; then
                if ! (finalize_retired_overlay_transaction "$transaction_root" release-install); then
                    cleanup_failed=1
                fi
            else
                cleanup_failed=1
            fi
        fi
        if [[ -n "$backup_verification_root" && -d "$backup_verification_root" && "$backup_verification_root" == "$local_state_root"/backup-check.* ]]; then
            /bin/rm -rf -- "$backup_verification_root" || cleanup_failed=1
        fi
        release_operation_lock || cleanup_failed=1
    fi
    if [[ "$cleanup_failed" != "0" && "$status" == "0" ]]; then
        status=1
    fi
    exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

acquire_operation_lock "$project_dir" product

if install_foreign_release_evidence_exists; then
    safety_die "an unfinished rollback operation exists; only rollback-personal.sh may reconcile it"
fi

if [[ -e "$install_preparing_root" || -L "$install_preparing_root" ]]; then
    [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] \
        || safety_die "installation preparation and active transaction evidence conflict"
    [[ ! -e "$install_cleanup_root" && ! -L "$install_cleanup_root" ]] \
        || safety_die "installation preparation and retired transaction evidence conflict"
    [[ -d "$install_preparing_root" && ! -L "$install_preparing_root" ]] \
        || safety_die "an unsafe installation preparation requires manual inspection"
    if [[ -e "$pending_manifest" || -L "$pending_manifest" ]]; then
        validate_install_pending_record \
            || safety_die "installation preparation conflicts with its pending record; all evidence was preserved"
    fi
    release_state_owned=1
    discard_abandoned_overlay_preparation "$transaction_root" release-install \
        || safety_die "the abandoned installation preparation could not be cleared safely"
    if [[ -e "$pending_manifest" || -L "$pending_manifest" ]]; then
        reconcile_pending_install \
            || safety_die "the abandoned installation preparation was removed, but its pending record needs inspection"
    fi
    safety_die "an interrupted installation preparation was cleared before any app change; run the command again"
fi

if [[ -e "$transaction_root" ]]; then
    [[ -d "$transaction_root" && ! -L "$transaction_root" && -f "$transaction_root/state" ]] \
        || safety_die "an invalid Release transaction requires manual inspection"
    transaction_operation_matches "$transaction_root" release-install \
        || safety_die "the Release transaction is not owned by install-personal.sh; its evidence was preserved"
    validate_install_transaction_evidence \
        || safety_die "the installation transaction conflicts with its pending record; all evidence was preserved"
    release_state_owned=1
    if ! recover_overlay_transaction "$target_app" "$transaction_root" release-install release_recovery_callback; then
        safety_die "the interrupted Release update could not be recovered; the transaction snapshot was preserved"
    fi
    if ! (reconcile_pending_install); then
        safety_die "the Release payload was recovered, but its installation record needs inspection"
    fi
    safety_die "the interrupted Release update was rolled back; run the command again"
fi

release_state_owned=1
if [[ -e "$install_cleanup_root" || -L "$install_cleanup_root" ]]; then
    [[ -d "$install_cleanup_root" && ! -L "$install_cleanup_root" ]] \
        || safety_die "an unsafe retired installation transaction requires manual inspection"
    if [[ -e "$pending_manifest" || -L "$pending_manifest" ]]; then
        if ! (reconcile_pending_install); then
            safety_die "the retired installation transaction does not match a verified installed payload"
        fi
    fi
    [[ ! -e "$pending_manifest" && ! -L "$pending_manifest" ]] \
        || safety_die "the retired installation transaction still has an unresolved pending record"
    finalize_retired_overlay_transaction "$transaction_root" release-install \
        || safety_die "the retired installation transaction could not be cleared safely"
    safety_die "an interrupted installation cleanup was reconciled; inspect the installed app and run the command again"
fi

if [[ -e "$pending_manifest" || -L "$pending_manifest" ]]; then
    if ! (reconcile_pending_install); then
        safety_die "an unfinished installation record does not match a verified payload"
    fi
    safety_die "an interrupted installation record was reconciled; inspect the installed app before running a newer candidate"
fi

if [[ -e "$pending_manifest_next" || -L "$pending_manifest_next" ]]; then
    [[ -f "$pending_manifest_next" && ! -L "$pending_manifest_next" ]] \
        || safety_die "an unsafe installation pending staging file requires manual inspection"
    /bin/rm -f "$pending_manifest_next" \
        || safety_die "the interrupted installation staging file could not be cleared"
    safety_die "an interrupted installation staging file was cleared; inspect the installed app and run the command again"
fi

assert_paths_absent \
    "unfinished Debug smoke check" \
    "$smoke_pending_manifest" \
    "$smoke_pending_manifest_next" \
    "$smoke_manifest_next"

require_clean_git "$project_dir"
"$script_dir/verify-iterm-handoff.sh"
current_head="$(git_head "$project_dir")"
assert_manifest_keys \
    "$candidate_manifest" \
    FORMAT_VERSION \
    GIT_HEAD \
    MARKETING_VERSION \
    BUILD_VERSION \
    APP_NAME \
    SIGNING_MODE \
    TEAM_ID \
    TREE_SHA256 \
    OUTER_REQUIREMENT_SHA256 \
    INNER_REQUIREMENT_SHA256 \
    SMOKE_RECEIPT_SHA256 \
    CREATED_AT
[[ "$(manifest_value "$candidate_manifest" FORMAT_VERSION)" == "1" ]] || safety_die "unsupported candidate manifest"
[[ "$(manifest_value "$candidate_manifest" GIT_HEAD)" == "$current_head" ]] || safety_die "candidate does not match the current commit"
[[ "$(manifest_value "$candidate_manifest" APP_NAME)" == "Go2Codex.app" ]] || safety_die "candidate app name is invalid"
[[ "$(manifest_value "$candidate_manifest" SIGNING_MODE)" == "stable-local" ]] || safety_die "candidate is not a stable local release"
candidate_marketing_version="$(manifest_value "$candidate_manifest" MARKETING_VERSION)"
candidate_build_version="$(manifest_value "$candidate_manifest" BUILD_VERSION)"
candidate_expected_tree="$(manifest_value "$candidate_manifest" TREE_SHA256)"
candidate_expected_team="$(manifest_value "$candidate_manifest" TEAM_ID)" || safety_die "candidate signing team is unavailable"
candidate_expected_outer_requirement="$(manifest_value "$candidate_manifest" OUTER_REQUIREMENT_SHA256)" || safety_die "candidate outer signing requirement is unavailable"
candidate_expected_inner_requirement="$(manifest_value "$candidate_manifest" INNER_REQUIREMENT_SHA256)" || safety_die "candidate Launcher signing requirement is unavailable"
candidate_expected_smoke_sha="$(manifest_value "$candidate_manifest" SMOKE_RECEIPT_SHA256)" || safety_die "candidate smoke receipt checksum is unavailable"
assert_positive_integer "$candidate_build_version" "candidate build number"

"$script_dir/verify-app.sh" \
    "$candidate_app" \
    Release \
    --signing stable-local \
    --marketing-version "$candidate_marketing_version" \
    --build-version "$candidate_build_version"
candidate_actual_tree="$(tree_fingerprint "$candidate_app")" || safety_die "candidate fingerprint failed"
candidate_actual_team="$(team_identifier "$candidate_app")" || safety_die "candidate signing team could not be inspected"
candidate_actual_outer_requirement="$(designated_requirement_hash "$candidate_app")" || safety_die "candidate outer signing requirement could not be inspected"
[[ "$candidate_actual_tree" == "$candidate_expected_tree" ]] \
    || safety_die "candidate tree does not match its manifest"
[[ -n "$candidate_actual_team" && "$candidate_actual_team" == "$candidate_expected_team" ]] \
    || safety_die "candidate signing team does not match its manifest"
[[ "$candidate_actual_outer_requirement" == "$candidate_expected_outer_requirement" ]] \
    || safety_die "candidate outer signing requirement does not match its manifest"
candidate_inner="$candidate_app/Contents/Helpers/Go2CodexLauncher.app"
candidate_actual_inner_requirement="$(designated_requirement_hash "$candidate_inner")" || safety_die "candidate Launcher signing requirement could not be inspected"
[[ "$candidate_actual_inner_requirement" == "$candidate_expected_inner_requirement" ]] \
    || safety_die "candidate Launcher signing requirement does not match its manifest"

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
smoke_expected_tree="$(manifest_value "$smoke_manifest" DEBUG_TREE_SHA256)" || safety_die "Debug smoke tree is unavailable"
smoke_team="$(manifest_value "$smoke_manifest" TEAM_ID)" || safety_die "Debug smoke signing team is unavailable"
smoke_outer_requirement="$(manifest_value "$smoke_manifest" OUTER_REQUIREMENT_SHA256)" || safety_die "Debug smoke outer signing requirement is unavailable"
smoke_inner_requirement="$(manifest_value "$smoke_manifest" INNER_REQUIREMENT_SHA256)" || safety_die "Debug smoke Launcher signing requirement is unavailable"
smoke_actual_sha="$(/usr/bin/shasum -a 256 "$smoke_manifest" | /usr/bin/awk '{ print $1 }')" || safety_die "Debug smoke receipt checksum could not be read"
[[ "$smoke_format" == "1" ]] || safety_die "unsupported Debug smoke receipt"
[[ "$smoke_head" == "$current_head" ]] || safety_die "Debug smoke check does not match the current commit"
[[ "$smoke_result" == "pass" ]] || safety_die "Debug smoke check did not pass"
[[ "$smoke_checklist" == "3" ]] || safety_die "Debug smoke checklist is obsolete"
[[ "$smoke_actual_sha" == "$candidate_expected_smoke_sha" ]] \
    || safety_die "Debug smoke receipt changed after the candidate was created"
"$script_dir/verify-app.sh" "$debug_app" Debug --signing stable-local
debug_actual_tree="$(tree_fingerprint "$debug_app")" || safety_die "installed Debug fingerprint failed"
debug_actual_team="$(team_identifier "$debug_app")" || safety_die "installed Debug signing team could not be inspected"
debug_actual_outer_requirement="$(designated_requirement_hash "$debug_app")" || safety_die "installed Debug outer signing requirement could not be inspected"
debug_actual_inner_requirement="$(designated_requirement_hash "$debug_app/Contents/Helpers/Go2CodexLauncher.app")" || safety_die "installed Debug Launcher signing requirement could not be inspected"
[[ "$debug_actual_tree" == "$smoke_expected_tree" ]] \
    || safety_die "installed Debug changed after the passing smoke check"
[[ -n "$debug_actual_team" && "$debug_actual_team" == "$candidate_expected_team" ]] \
    || safety_die "installed Debug and Release candidate use different signing teams"
[[ "$smoke_team" == "$candidate_expected_team" ]] \
    || safety_die "Debug smoke check used a different signing team"
[[ "$smoke_outer_requirement" == "$debug_actual_outer_requirement" ]] \
    || safety_die "Debug outer signing identity changed after the passing smoke check"
[[ "$smoke_inner_requirement" == "$debug_actual_inner_requirement" ]] \
    || safety_die "Debug Launcher signing identity changed after the passing smoke check"

previous_mode="NONE"
previous_marketing="NONE"
previous_build="NONE"
previous_tree="absent"
previous_outer_requirement=""
previous_inner_requirement=""
if [[ -e "$target_app" ]]; then
    [[ -d "$target_app" && ! -L "$target_app" ]] || safety_die "installed Personal Release is unsafe"
    previous_mode="$(signature_mode "$target_app")"
    previous_marketing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target_app/Contents/Info.plist")"
    previous_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target_app/Contents/Info.plist")"
    "$script_dir/verify-app.sh" \
        "$target_app" \
        Release \
        --signing "$previous_mode" \
        --content compatible \
        --marketing-version "$previous_marketing" \
        --build-version "$previous_build"
    previous_tree="$(tree_fingerprint "$target_app")"
    expected_previous_release_tree="$previous_tree"
    previous_outer_requirement="$(designated_requirement_hash "$target_app")"
    previous_inner_path="$(compatible_launcher_path "$target_app")" \
        || safety_die "installed Personal Release Launcher location is missing, ambiguous, or unsafe"
    previous_inner_requirement="$(designated_requirement_hash "$previous_inner_path")"
    assert_newer_build_number "$candidate_build_version" "$previous_build"
    expected_outer_inode="$(/usr/bin/stat -f '%i' "$target_app")"
    if [[ "$previous_inner_path" == "$target_app/Contents/Helpers/Go2CodexLauncher.app" ]]; then
        expected_inner_inode="$(/usr/bin/stat -f '%i' "$previous_inner_path")"
    fi
fi

if [[ "$install_mode" == "normal" ]]; then
    if [[ "$previous_mode" != "NONE" ]]; then
        [[ "$previous_mode" == "stable-local" ]] || safety_die "normal updates require an already migrated stable-local Release"
        [[ "$previous_outer_requirement" == "$(designated_requirement_hash "$candidate_app")" ]] || safety_die "outer signing identity changed"
        [[ "$previous_inner_requirement" == "$(designated_requirement_hash "$candidate_inner")" ]] || safety_die "Launcher signing identity changed"
    fi
else
    [[ "$previous_mode" == "adhoc" ]] || safety_die "the one-time migration option requires an existing ad-hoc Release"
fi

terminate_exact_app_processes \
    "$target_app/Contents/MacOS/Go2Codex" \
    "$previous_inner_path/Contents/MacOS/Go2CodexLauncher"

if [[ ! -e "$backup_root" ]]; then
    /bin/mkdir "$backup_root"
fi
[[ -d "$backup_root" && ! -L "$backup_root" ]] || safety_die "Release backup directory is unsafe"

prepare_overlay_transaction "$candidate_app" "$target_app" "$transaction_root" release-install

backup_file="NONE"
backup_sha="NONE"
if [[ "$previous_mode" != "NONE" ]]; then
    backup_file="Go2Codex-$previous_marketing-$previous_build-$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$$.zip"
    backup_path="$backup_root/$backup_file"
    [[ "$backup_path" != *.app ]] || safety_die "Release backup path must not end in .app"
    assert_no_symlink_components "$backup_path" "Release backup path"
    [[ ! -e "$backup_path" && ! -L "$backup_path" ]] || safety_die "Release backup path already exists"
    /usr/bin/ditto -c -k --keepParent "$transaction_root/previous.payload" "$backup_path"
    /usr/bin/unzip -tq "$backup_path" >/dev/null
    backup_sha="$(/usr/bin/shasum -a 256 "$backup_path" | /usr/bin/awk '{ print $1 }')"
    [[ -n "$backup_sha" ]] || safety_die "Release backup checksum is empty"
    backup_verification_root="$(mktemp -d "$local_state_root/backup-check.XXXXXX")" || safety_die "Release backup verification directory could not be created"
    /usr/bin/ditto -x -k "$backup_path" "$backup_verification_root" || safety_die "Release backup could not be extracted for verification"
    backup_verification_payload="$backup_verification_root/previous.payload"
    backup_verification_source="$backup_verification_root/Go2Codex.app"
    rename_extracted_app_for_verification \
        "$backup_verification_payload" \
        "$backup_verification_source" \
        Go2Codex.app \
        "Release backup verification"
    backup_top_level_count="$(/usr/bin/find "$backup_verification_root" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
        || safety_die "Release backup contents could not be enumerated"
    [[ "$backup_top_level_count" == "1" ]] || safety_die "Release backup contains unexpected top-level entries"
    backup_tree="$(tree_fingerprint "$backup_verification_source")" || safety_die "Release backup fingerprint failed"
    [[ "$backup_tree" == "$previous_tree" ]] || safety_die "Release backup differs from the installed snapshot"
    "$script_dir/verify-app.sh" \
        "$backup_verification_source" \
        Release \
        --signing "$previous_mode" \
        --content compatible \
        --marketing-version "$previous_marketing" \
        --build-version "$previous_build"
    /bin/rm -rf -- "$backup_verification_root" || safety_die "Release backup verification directory could not be removed"
    backup_verification_root=""
fi

if [[ "$install_mode" == "migrate" ]]; then
    migration_value=1
else
    migration_value=0
fi
prepare_regular_output_path "$pending_manifest_next" "installation pending staging file"
assert_safe_regular_output_path "$pending_manifest" "installation pending record"
/usr/bin/printf \
    'FORMAT_VERSION=1\nGIT_HEAD=%s\nNEW_TREE_SHA256=%s\nNEW_MARKETING_VERSION=%s\nNEW_BUILD_VERSION=%s\nPREVIOUS_TREE_SHA256=%s\nPREVIOUS_SIGNING_MODE=%s\nPREVIOUS_MARKETING_VERSION=%s\nPREVIOUS_BUILD_VERSION=%s\nBACKUP_FILE=%s\nBACKUP_SHA256=%s\nMIGRATION=%s\n' \
    "$current_head" \
    "$candidate_expected_tree" \
    "$candidate_marketing_version" \
    "$candidate_build_version" \
    "$previous_tree" \
    "$previous_mode" \
    "$previous_marketing" \
    "$previous_build" \
    "$backup_file" \
    "$backup_sha" \
    "$migration_value" \
    >"$pending_manifest_next" \
    || safety_die "installation pending record could not be written"
atomic_replace_regular_file "$pending_manifest_next" "$pending_manifest" "installation pending record" \
    || safety_die "installation pending record could not be committed"

unset GO2CODEX_TRANSACTION_FAIL_STAGE || true
commit_overlay_transaction \
    "$target_app" \
    "$transaction_root" \
    release-install \
    release_verify_callback \
    release_register_callback \
    release_recovery_callback

reconcile_pending_install
[[ -f "$last_install_manifest" && ! -L "$last_install_manifest" ]] || safety_die "completed installation record is missing"
install_complete=1
echo "install-personal: verified candidate installed at the stable path; no app was launched, Finder was not restarted, and TCC was not reset"
if [[ "$install_mode" == "migrate" ]]; then
    echo "install-personal: the signing identity was migrated once; macOS may request Automation permission again"
fi
echo "请现在完成普通文件夹、最近使用、Shift 选择器和 iTerm2 的正式版冒烟检查；失败时立即运行 ./Scripts/rollback-personal.sh --confirm-rollback。"
