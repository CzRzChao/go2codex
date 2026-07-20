#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 || "$1" != "--confirm-rollback" ]]; then
    echo "Usage: $0 --confirm-rollback" >&2
    exit 64
fi

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
backup_root="$local_state_root/backups"
last_install_manifest="$local_state_root/last-install.manifest"
rolled_back_manifest="$local_state_root/last-rollback.manifest"
rollback_pending_manifest="$local_state_root/rollback.pending"
rollback_pending_manifest_next="$local_state_root/rollback.pending.next"
rollback_receipt_next="$local_state_root/last-rollback.manifest.next"
install_pending_manifest="$local_state_root/install.pending"
install_pending_manifest_next="$local_state_root/install.pending.next"
install_preparing_root="$transaction_root.release-install.preparing"
rollback_preparing_root="$transaction_root.release-rollback.preparing"
install_cleanup_root="$transaction_root.release-install.cleanup"
rollback_cleanup_root="$transaction_root.release-rollback.cleanup"
legacy_preparing_root="$transaction_root.preparing"
extraction_root=""
restore_source=""
restore_mode=""
restore_marketing=""
restore_build=""
current_marketing=""
current_build=""
current_tree=""
expected_outer_inode=""
expected_inner_inode=""
rollback_complete=0
release_state_owned=0

[[ -d "$applications_dir" && ! -L "$applications_dir" ]] || safety_die "the user Applications directory is missing or unsafe"
assert_exact_path "$target_app" "$user_home/Applications/Go2Codex.app" "Personal Release path"
assert_exact_path "$transaction_root" "$user_home/Applications/.go2codex-update" "Personal Release transaction path"
[[ ! -e "$system_app" && ! -L "$system_app" ]] || safety_die "a second system-wide Go2Codex.app exists; rollback is ambiguous"
[[ -d "$local_state_root" && ! -L "$local_state_root" ]] || safety_die "local release state is missing or unsafe"
assert_no_symlink_components "$backup_root" "Release backup directory"
assert_no_symlink_components "$rollback_pending_manifest" "rollback pending record"
assert_no_symlink_components "$rollback_pending_manifest_next" "rollback pending staging file"
assert_no_symlink_components "$last_install_manifest" "last installation record"
assert_no_symlink_components "$rolled_back_manifest" "rollback receipt"
assert_no_symlink_components "$rollback_receipt_next" "rollback receipt staging file"
assert_no_symlink_components "$install_pending_manifest" "installation pending record"
assert_no_symlink_components "$install_pending_manifest_next" "installation pending staging file"
assert_no_symlink_components "$install_preparing_root" "installation transaction preparation"
assert_no_symlink_components "$rollback_preparing_root" "rollback transaction preparation"
assert_no_symlink_components "$install_cleanup_root" "retired installation transaction"
assert_no_symlink_components "$rollback_cleanup_root" "retired rollback transaction"
assert_no_symlink_components "$legacy_preparing_root" "legacy transaction preparation"

rollback_foreign_release_evidence_exists() {
    local path

    for path in \
        "$install_pending_manifest" \
        "$install_pending_manifest_next" \
        "$install_preparing_root" \
        "$install_cleanup_root" \
        "$legacy_preparing_root"; do
        if [[ -e "$path" || -L "$path" ]]; then
            return 0
        fi
    done
    return 1
}

generic_recovery_callback() {
    local restored="$1"
    local had_previous="$2"
    if [[ "$had_previous" == "true" ]]; then
        local previous_mode
        local previous_marketing
        local previous_build
        local previous_tree
        local restored_tree
        local expected_previous_tree="$current_tree"
        previous_mode="$(signature_mode "$restored")" || return 1
        previous_marketing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$restored/Contents/Info.plist")" || return 1
        previous_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$restored/Contents/Info.plist")" || return 1
        previous_tree="$(transaction_state_value "$transaction_root" PREVIOUS_TREE_SHA256)" || return 1
        restored_tree="$(tree_fingerprint "$restored")" || return 1
        [[ "$restored_tree" == "$previous_tree" ]] || return 1
        if [[ -f "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]]; then
            expected_previous_tree="$(manifest_value "$rollback_pending_manifest" CURRENT_TREE_SHA256)" || return 1
        fi
        if [[ -n "$expected_previous_tree" ]]; then
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

rollback_verify_callback() {
    local installed="$1"
    local staged="$2"
    local installed_tree
    local staged_tree
    "$script_dir/verify-app.sh" \
        "$installed" \
        Release \
        --signing "$restore_mode" \
        --content compatible \
        --marketing-version "$restore_marketing" \
        --build-version "$restore_build" \
        || return 1
    installed_tree="$(tree_fingerprint "$installed")" || return 1
    staged_tree="$(tree_fingerprint "$staged")" || return 1
    [[ "$installed_tree" == "$staged_tree" ]] || return 1
    [[ -n "$restore_tree" && "$installed_tree" == "$restore_tree" ]] || return 1
    [[ "$(/usr/bin/stat -f '%i' "$installed")" == "$expected_outer_inode" ]] || return 1
    [[ "$(/usr/bin/stat -f '%i' "$installed/Contents/Applications/Go2CodexLauncher.app")" == "$expected_inner_inode" ]] || return 1
    return 0
}

rollback_register_callback() {
    register_exact_app "$1" || return 1
    return 0
}

validate_rollback_pending_record() {
    local format
    local current_tree_value
    local current_marketing_value
    local current_build_value
    local restore_tree_value
    local restore_mode_value
    local restore_marketing_value
    local restore_build_value
    local install_sha_value
    local started_at_value

    assert_manifest_keys \
        "$rollback_pending_manifest" \
        FORMAT_VERSION \
        CURRENT_TREE_SHA256 \
        CURRENT_MARKETING_VERSION \
        CURRENT_BUILD_VERSION \
        RESTORE_TREE_SHA256 \
        RESTORE_SIGNING_MODE \
        RESTORE_MARKETING_VERSION \
        RESTORE_BUILD_VERSION \
        LAST_INSTALL_SHA256 \
        STARTED_AT \
        || return 1
    format="$(manifest_value "$rollback_pending_manifest" FORMAT_VERSION)" || return 1
    current_tree_value="$(manifest_value "$rollback_pending_manifest" CURRENT_TREE_SHA256)" || return 1
    current_marketing_value="$(manifest_value "$rollback_pending_manifest" CURRENT_MARKETING_VERSION)" || return 1
    current_build_value="$(manifest_value "$rollback_pending_manifest" CURRENT_BUILD_VERSION)" || return 1
    restore_tree_value="$(manifest_value "$rollback_pending_manifest" RESTORE_TREE_SHA256)" || return 1
    restore_mode_value="$(manifest_value "$rollback_pending_manifest" RESTORE_SIGNING_MODE)" || return 1
    restore_marketing_value="$(manifest_value "$rollback_pending_manifest" RESTORE_MARKETING_VERSION)" || return 1
    restore_build_value="$(manifest_value "$rollback_pending_manifest" RESTORE_BUILD_VERSION)" || return 1
    install_sha_value="$(manifest_value "$rollback_pending_manifest" LAST_INSTALL_SHA256)" || return 1
    started_at_value="$(manifest_value "$rollback_pending_manifest" STARTED_AT)" || return 1

    [[ "$format" == "1" ]] || return 1
    [[ "$current_tree_value" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$restore_tree_value" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$current_marketing_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$restore_marketing_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$current_build_value" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$restore_build_value" =~ ^[1-9][0-9]*$ ]] || return 1
    case "$restore_mode_value" in
        adhoc|stable-local) ;;
        *) return 1 ;;
    esac
    [[ "$install_sha_value" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$started_at_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    assert_rollback_source_record "$last_install_manifest" "$rolled_back_manifest" "$install_sha_value" || return 1
    return 0
}

validate_rollback_transaction_evidence() {
    local transaction_previous
    local transaction_next
    local pending_current
    local pending_restore

    transaction_operation_matches "$transaction_root" release-rollback || return 1
    validate_transaction_payloads "$transaction_root" false || return 1
    [[ -f "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]] || return 1
    validate_rollback_pending_record || return 1
    transaction_previous="$(transaction_state_value "$transaction_root" PREVIOUS_TREE_SHA256)" || return 1
    transaction_next="$(transaction_state_value "$transaction_root" NEXT_TREE_SHA256)" || return 1
    pending_current="$(manifest_value "$rollback_pending_manifest" CURRENT_TREE_SHA256)" || return 1
    pending_restore="$(manifest_value "$rollback_pending_manifest" RESTORE_TREE_SHA256)" || return 1
    [[ "$transaction_previous" == "$pending_current" ]] || return 1
    [[ "$transaction_next" == "$pending_restore" ]] || return 1
    return 0
}

reconcile_pending_rollback() {
    if [[ ! -e "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]]; then
        return 0
    fi
    [[ -f "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]] || return 1
    validate_rollback_pending_record || return 1

    local pending_format
    local pending_current_tree
    local pending_current_marketing
    local pending_current_build
    local pending_restore_tree
    local pending_restore_mode
    local pending_restore_marketing
    local pending_restore_build
    local pending_install_sha
    local actual_tree
    local actual_install_sha
    local recorded_source_sha
    local rolled_back_at
    pending_format="$(manifest_value "$rollback_pending_manifest" FORMAT_VERSION)" || return 1
    pending_current_tree="$(manifest_value "$rollback_pending_manifest" CURRENT_TREE_SHA256)" || return 1
    pending_current_marketing="$(manifest_value "$rollback_pending_manifest" CURRENT_MARKETING_VERSION)" || return 1
    pending_current_build="$(manifest_value "$rollback_pending_manifest" CURRENT_BUILD_VERSION)" || return 1
    pending_restore_tree="$(manifest_value "$rollback_pending_manifest" RESTORE_TREE_SHA256)" || return 1
    pending_restore_mode="$(manifest_value "$rollback_pending_manifest" RESTORE_SIGNING_MODE)" || return 1
    pending_restore_marketing="$(manifest_value "$rollback_pending_manifest" RESTORE_MARKETING_VERSION)" || return 1
    pending_restore_build="$(manifest_value "$rollback_pending_manifest" RESTORE_BUILD_VERSION)" || return 1
    pending_install_sha="$(manifest_value "$rollback_pending_manifest" LAST_INSTALL_SHA256)" || return 1
    [[ "$pending_format" == "1" ]] || return 1
    [[ -d "$target_app" && ! -L "$target_app" ]] || {
        echo "rollback-personal: rollback target is missing while a pending record exists" >&2
        return 1
    }
    actual_tree="$(tree_fingerprint "$target_app")" || return 1

    if [[ "$actual_tree" == "$pending_current_tree" ]]; then
        [[ -f "$last_install_manifest" && ! -L "$last_install_manifest" ]] || return 1
        actual_install_sha="$(/usr/bin/shasum -a 256 "$last_install_manifest" | /usr/bin/awk '{ print $1 }')" || return 1
        [[ "$actual_install_sha" == "$pending_install_sha" ]] || return 1
        "$script_dir/verify-app.sh" \
            "$target_app" \
            Release \
            --signing stable-local \
            --content compatible \
            --marketing-version "$pending_current_marketing" \
            --build-version "$pending_current_build" \
            || return 1
        /bin/rm -f "$rollback_pending_manifest" || return 1
        return 0
    fi

    if [[ "$actual_tree" == "$pending_restore_tree" ]]; then
        "$script_dir/verify-app.sh" \
            "$target_app" \
            Release \
            --signing "$pending_restore_mode" \
            --content compatible \
            --marketing-version "$pending_restore_marketing" \
            --build-version "$pending_restore_build" \
            || return 1

        if [[ -f "$last_install_manifest" && ! -L "$last_install_manifest" ]]; then
            actual_install_sha="$(/usr/bin/shasum -a 256 "$last_install_manifest" | /usr/bin/awk '{ print $1 }')" || return 1
            [[ "$actual_install_sha" == "$pending_install_sha" ]] || return 1
            if [[ -e "$rollback_receipt_next" || -L "$rollback_receipt_next" ]]; then
                [[ -f "$rollback_receipt_next" && ! -L "$rollback_receipt_next" ]] || return 1
                /bin/rm -f "$rollback_receipt_next" || return 1
            fi
            /bin/cp "$last_install_manifest" "$rollback_receipt_next" || return 1
            rolled_back_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
            /usr/bin/printf \
                'ROLLBACK_SOURCE_SHA256=%s\nROLLED_BACK_AT=%s\n' \
                "$pending_install_sha" \
                "$rolled_back_at" \
                >>"$rollback_receipt_next" \
                || return 1
            assert_manifest_keys \
                "$rollback_receipt_next" \
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
                ROLLBACK_SOURCE_SHA256 \
                ROLLED_BACK_AT \
                || return 1
            recorded_source_sha="$(manifest_value "$rollback_receipt_next" ROLLBACK_SOURCE_SHA256)" || return 1
            [[ "$recorded_source_sha" == "$pending_install_sha" ]] || return 1
            atomic_replace_regular_file "$rollback_receipt_next" "$rolled_back_manifest" "rollback receipt" || return 1
            recorded_source_sha="$(manifest_value "$rolled_back_manifest" ROLLBACK_SOURCE_SHA256)" || return 1
            [[ "$recorded_source_sha" == "$pending_install_sha" ]] || return 1
            /bin/rm -f "$last_install_manifest" || return 1
        else
            assert_manifest_keys \
                "$rolled_back_manifest" \
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
                ROLLBACK_SOURCE_SHA256 \
                ROLLED_BACK_AT \
                || return 1
            recorded_source_sha="$(manifest_value "$rolled_back_manifest" ROLLBACK_SOURCE_SHA256)" || return 1
            [[ "$recorded_source_sha" == "$pending_install_sha" ]] || return 1
        fi
        /bin/rm -f "$rollback_pending_manifest" || return 1
        return 0
    fi

    echo "rollback-personal: pending rollback matches neither verified payload; preserving all records" >&2
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
            && ! rollback_foreign_release_evidence_exists; then
            if (validate_rollback_transaction_evidence); then
                if ! (recover_overlay_transaction "$target_app" "$transaction_root" release-rollback generic_recovery_callback); then
                    cleanup_failed=1
                else
                    cleanup_failed=1
                fi
            else
                cleanup_failed=1
            fi
        fi
        if [[ "$release_state_owned" == "1" && ( -e "$rollback_pending_manifest" || -L "$rollback_pending_manifest" ) && ! -e "$transaction_root" ]] \
            && ! rollback_foreign_release_evidence_exists; then
            if ! (reconcile_pending_rollback); then
                cleanup_failed=1
            fi
        fi
        if [[ "$release_state_owned" == "1" && -f "$rollback_receipt_next" && ! -L "$rollback_receipt_next" ]] \
            && [[ ! -e "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]] \
            && [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] \
            && ! rollback_foreign_release_evidence_exists; then
            /bin/rm -f "$rollback_receipt_next" || cleanup_failed=1
        fi
        if [[ "$release_state_owned" == "1" && ( -e "$rollback_cleanup_root" || -L "$rollback_cleanup_root" ) && ! -e "$transaction_root" ]] \
            && ! rollback_foreign_release_evidence_exists; then
            if [[ ! -e "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]]; then
                if ! (finalize_retired_overlay_transaction "$transaction_root" release-rollback); then
                    cleanup_failed=1
                fi
            else
                cleanup_failed=1
            fi
        fi
        if [[ -n "$extraction_root" && -d "$extraction_root" && "$extraction_root" == "$local_state_root"/rollback.* ]]; then
            /bin/rm -rf -- "$extraction_root" || cleanup_failed=1
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

if rollback_foreign_release_evidence_exists; then
    safety_die "an unfinished installation operation exists; only install-personal.sh may reconcile it"
fi

if [[ -e "$rollback_preparing_root" || -L "$rollback_preparing_root" ]]; then
    [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] \
        || safety_die "rollback preparation and active transaction evidence conflict"
    [[ ! -e "$rollback_cleanup_root" && ! -L "$rollback_cleanup_root" ]] \
        || safety_die "rollback preparation and retired transaction evidence conflict"
    [[ -d "$rollback_preparing_root" && ! -L "$rollback_preparing_root" ]] \
        || safety_die "an unsafe rollback preparation requires manual inspection"
    [[ -f "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]] \
        || safety_die "rollback preparation is missing its required pending record"
    validate_rollback_pending_record \
        || safety_die "rollback preparation conflicts with its pending record; all evidence was preserved"
    release_state_owned=1
    discard_abandoned_overlay_preparation "$transaction_root" release-rollback \
        || safety_die "the abandoned rollback preparation could not be cleared safely"
    reconcile_pending_rollback \
        || safety_die "the abandoned rollback preparation was removed, but its pending record needs inspection"
    safety_die "an interrupted rollback preparation was cleared before any app change; inspect the app and run the command again"
fi

if [[ -e "$transaction_root" ]]; then
    [[ -d "$transaction_root" && ! -L "$transaction_root" && -f "$transaction_root/state" ]] \
        || safety_die "an invalid Release transaction requires manual inspection"
    transaction_operation_matches "$transaction_root" release-rollback \
        || safety_die "the Release transaction is not owned by rollback-personal.sh; its evidence was preserved"
    [[ -f "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]] \
        || safety_die "a rollback-owned transaction without its pending record requires manual inspection"
    validate_rollback_transaction_evidence \
        || safety_die "the rollback transaction conflicts with its pending or installation record; all evidence was preserved"
    release_state_owned=1
    if ! recover_overlay_transaction "$target_app" "$transaction_root" release-rollback generic_recovery_callback; then
        safety_die "the interrupted Release operation could not be recovered; the transaction snapshot was preserved"
    fi
    if ! (reconcile_pending_rollback); then
        safety_die "the Release payload was recovered, but its rollback record needs inspection"
    fi
    safety_die "the interrupted Release operation was recovered; inspect the app before requesting rollback again"
fi

release_state_owned=1
if [[ -e "$rollback_cleanup_root" || -L "$rollback_cleanup_root" ]]; then
    [[ -d "$rollback_cleanup_root" && ! -L "$rollback_cleanup_root" ]] \
        || safety_die "an unsafe retired rollback transaction requires manual inspection"
    if [[ -e "$rollback_pending_manifest" || -L "$rollback_pending_manifest" ]]; then
        if ! (reconcile_pending_rollback); then
            safety_die "the retired rollback transaction does not match a verified installed payload"
        fi
    fi
    [[ ! -e "$rollback_pending_manifest" && ! -L "$rollback_pending_manifest" ]] \
        || safety_die "the retired rollback transaction still has an unresolved pending record"
    finalize_retired_overlay_transaction "$transaction_root" release-rollback \
        || safety_die "the retired rollback transaction could not be cleared safely"
    safety_die "an interrupted rollback cleanup was reconciled; inspect the installed app and run the command again"
fi

if [[ -e "$rollback_pending_manifest" || -L "$rollback_pending_manifest" ]]; then
    if ! (reconcile_pending_rollback); then
        safety_die "an unfinished rollback record does not match a verified payload"
    fi
    safety_die "an interrupted rollback record was reconciled; inspect the installed app before continuing"
fi

if [[ -e "$rollback_pending_manifest_next" || -L "$rollback_pending_manifest_next" ]]; then
    [[ -f "$rollback_pending_manifest_next" && ! -L "$rollback_pending_manifest_next" ]] \
        || safety_die "an unsafe rollback pending staging file requires manual inspection"
    /bin/rm -f "$rollback_pending_manifest_next" \
        || safety_die "the interrupted rollback staging file could not be cleared"
    safety_die "an interrupted rollback staging file was cleared; inspect the installed app and run the command again"
fi

assert_manifest_keys \
    "$last_install_manifest" \
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
    MIGRATION
[[ "$(manifest_value "$last_install_manifest" FORMAT_VERSION)" == "1" ]] || safety_die "unsupported rollback manifest"
[[ -d "$target_app" && ! -L "$target_app" ]] || safety_die "the installed Release is missing or unsafe"

current_tree="$(manifest_value "$last_install_manifest" NEW_TREE_SHA256)"
current_marketing="$(manifest_value "$last_install_manifest" NEW_MARKETING_VERSION)"
current_build="$(manifest_value "$last_install_manifest" NEW_BUILD_VERSION)"
[[ "$(tree_fingerprint "$target_app")" == "$current_tree" ]] || safety_die "installed Release no longer matches the recorded update"
"$script_dir/verify-app.sh" \
    "$target_app" \
    Release \
    --signing stable-local \
    --content compatible \
    --marketing-version "$current_marketing" \
    --build-version "$current_build"

backup_file="$(manifest_value "$last_install_manifest" BACKUP_FILE)"
backup_sha="$(manifest_value "$last_install_manifest" BACKUP_SHA256)"
[[ "$backup_file" != "NONE" ]] || safety_die "this was a fresh installation and has no previous Release to restore"
[[ "$backup_file" != */* && "$backup_file" == *.zip ]] || safety_die "recorded backup file name is unsafe"
backup_path="$backup_root/$backup_file"
assert_no_symlink_components "$backup_path" "recorded Release backup"
[[ -f "$backup_path" && ! -L "$backup_path" ]] || safety_die "recorded Release backup is missing or unsafe"
[[ "$(/usr/bin/shasum -a 256 "$backup_path" | /usr/bin/awk '{ print $1 }')" == "$backup_sha" ]] || safety_die "Release backup checksum does not match"
/usr/bin/unzip -tq "$backup_path" >/dev/null

restore_mode="$(manifest_value "$last_install_manifest" PREVIOUS_SIGNING_MODE)"
restore_marketing="$(manifest_value "$last_install_manifest" PREVIOUS_MARKETING_VERSION)"
restore_build="$(manifest_value "$last_install_manifest" PREVIOUS_BUILD_VERSION)"
restore_tree="$(manifest_value "$last_install_manifest" PREVIOUS_TREE_SHA256)"
case "$restore_mode" in
    adhoc|stable-local) ;;
    *) safety_die "recorded previous signing mode cannot be restored" ;;
esac

extraction_root="$(mktemp -d "$local_state_root/rollback.XXXXXX")"
/usr/bin/ditto -x -k "$backup_path" "$extraction_root"
restore_payload="$extraction_root/previous.payload"
restore_source="$extraction_root/Go2Codex.app"
rename_extracted_app_for_verification \
    "$restore_payload" \
    "$restore_source" \
    Go2Codex.app \
    "Release rollback extraction"
extracted_restore_tree="$(tree_fingerprint "$restore_source")" || safety_die "extracted backup fingerprint failed"
[[ "$extracted_restore_tree" == "$restore_tree" ]] || safety_die "extracted backup tree does not match the recorded Release"
"$script_dir/verify-app.sh" \
    "$restore_source" \
    Release \
    --signing "$restore_mode" \
    --content compatible \
    --marketing-version "$restore_marketing" \
    --build-version "$restore_build"

terminate_exact_app_processes \
    "$target_app/Contents/MacOS/Go2Codex" \
    "$target_app/Contents/Applications/Go2CodexLauncher.app/Contents/MacOS/Go2CodexLauncher"
expected_outer_inode="$(/usr/bin/stat -f '%i' "$target_app")"
expected_inner_inode="$(/usr/bin/stat -f '%i' "$target_app/Contents/Applications/Go2CodexLauncher.app")"

last_install_sha="$(/usr/bin/shasum -a 256 "$last_install_manifest" | /usr/bin/awk '{ print $1 }')"
[[ -n "$last_install_sha" ]] || safety_die "last installation record checksum is empty"
rollback_started_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || safety_die "rollback start time could not be recorded"
prepare_regular_output_path "$rollback_pending_manifest_next" "rollback pending staging file"
assert_safe_regular_output_path "$rollback_pending_manifest" "rollback pending record"
/usr/bin/printf \
    'FORMAT_VERSION=1\nCURRENT_TREE_SHA256=%s\nCURRENT_MARKETING_VERSION=%s\nCURRENT_BUILD_VERSION=%s\nRESTORE_TREE_SHA256=%s\nRESTORE_SIGNING_MODE=%s\nRESTORE_MARKETING_VERSION=%s\nRESTORE_BUILD_VERSION=%s\nLAST_INSTALL_SHA256=%s\nSTARTED_AT=%s\n' \
    "$current_tree" \
    "$current_marketing" \
    "$current_build" \
    "$restore_tree" \
    "$restore_mode" \
    "$restore_marketing" \
    "$restore_build" \
    "$last_install_sha" \
    "$rollback_started_at" \
    >"$rollback_pending_manifest_next" \
    || safety_die "rollback pending record could not be written"
atomic_replace_regular_file "$rollback_pending_manifest_next" "$rollback_pending_manifest" "rollback pending record" \
    || safety_die "rollback pending record could not be committed"

prepare_overlay_transaction "$restore_source" "$target_app" "$transaction_root" release-rollback

unset GO2CODEX_TRANSACTION_FAIL_STAGE || true
commit_overlay_transaction \
    "$target_app" \
    "$transaction_root" \
    release-rollback \
    rollback_verify_callback \
    rollback_register_callback \
    generic_recovery_callback

reconcile_pending_rollback
[[ -f "$rolled_back_manifest" && ! -L "$rolled_back_manifest" ]] || safety_die "completed rollback receipt is missing"
rollback_complete=1
echo "rollback-personal: restored and verified the previous Release at the same Finder path; nothing was launched and TCC was not reset"
if [[ "$restore_mode" == "adhoc" ]]; then
    echo "rollback-personal: the restored legacy build is ad-hoc signed, so Automation permission continuity is not guaranteed"
fi
