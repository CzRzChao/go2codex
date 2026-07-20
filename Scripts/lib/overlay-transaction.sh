#!/usr/bin/env bash

set -euo pipefail

overlay_exact_tree() {
    local source="$1"
    local target="$2"

    [[ -d "$source" && ! -L "$source" ]] || safety_die "overlay source is missing or unsafe"
    [[ "$source" != "$target" ]] || safety_die "overlay source and target must differ"
    if [[ -e "$target" ]]; then
        [[ -d "$target" && ! -L "$target" ]] || safety_die "overlay target is not a real directory"
    else
        /bin/mkdir "$target" || return 1
    fi
    /usr/bin/rsync -aE --delete --checksum -- "$source/" "$target/" || return 1
    return 0
}

transaction_state_value() {
    local transaction_root="$1"
    local key="$2"
    manifest_value "$transaction_root/state" "$key"
}

assert_transaction_operation_name() {
    case "$1" in
        debug-install|release-install|release-rollback|sop-test) ;;
        *) safety_die "unknown transaction operation: $1" ;;
    esac
}

retired_transaction_root() {
    local transaction_root="$1"
    local operation="$2"

    assert_transaction_operation_name "$operation"
    /usr/bin/printf '%s\n' "$transaction_root.$operation.cleanup"
}

preparing_transaction_root() {
    local transaction_root="$1"
    local operation="$2"

    assert_transaction_operation_name "$operation"
    /usr/bin/printf '%s\n' "$transaction_root.$operation.preparing"
}

discard_abandoned_overlay_preparation() {
    local transaction_root="$1"
    local operation="$2"
    local preparing_root
    local cleanup_root

    preparing_root="$(preparing_transaction_root "$transaction_root" "$operation")" || return 1
    cleanup_root="$(retired_transaction_root "$transaction_root" "$operation")" || return 1
    [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] || return 1
    [[ ! -e "$cleanup_root" && ! -L "$cleanup_root" ]] || return 1
    if [[ ! -e "$preparing_root" && ! -L "$preparing_root" ]]; then
        return 0
    fi
    [[ -d "$preparing_root" && ! -L "$preparing_root" ]] || return 1
    assert_no_symlink_components "$preparing_root" "abandoned transaction preparation" || return 1
    /bin/rm -rf -- "$preparing_root" || return 1
    return 0
}

finalize_retired_overlay_transaction() {
    local transaction_root="$1"
    local operation="$2"
    local cleanup_root

    cleanup_root="$(retired_transaction_root "$transaction_root" "$operation")" || return 1
    [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] || return 1
    if [[ ! -e "$cleanup_root" && ! -L "$cleanup_root" ]]; then
        return 0
    fi
    [[ -d "$cleanup_root" && ! -L "$cleanup_root" ]] || return 1
    assert_no_symlink_components "$cleanup_root" "retired transaction cleanup" || return 1
    /bin/rm -rf -- "$cleanup_root" || return 1
    return 0
}

retire_overlay_transaction() {
    local transaction_root="$1"
    local operation="$2"
    local cleanup_root

    cleanup_root="$(retired_transaction_root "$transaction_root" "$operation")" || return 1
    [[ -d "$transaction_root" && ! -L "$transaction_root" ]] || return 1
    [[ ! -e "$cleanup_root" && ! -L "$cleanup_root" ]] || return 1
    assert_no_symlink_components "$cleanup_root" "retired transaction cleanup" || return 1
    /bin/mv "$transaction_root" "$cleanup_root" || return 1
    if [[ "${GO2CODEX_TRANSACTION_FAIL_STAGE:-}" == "cleanup_delete" ]]; then
        return 1
    fi
    finalize_retired_overlay_transaction "$transaction_root" "$operation" || return 1
    return 0
}

prepare_overlay_transaction() {
    local source="$1"
    local target="$2"
    local transaction_root="$3"
    local operation="$4"
    local preparing_root="$transaction_root.$operation.preparing"
    local cleanup_root="$transaction_root.$operation.cleanup"
    local previous_payload="$preparing_root/previous.payload"
    local next_payload="$preparing_root/next.payload"
    local had_previous=0
    local source_tree
    local staged_tree
    local target_tree
    local snapshot_tree

    assert_transaction_operation_name "$operation"
    [[ -d "$source" && ! -L "$source" ]] || safety_die "transaction source is missing or unsafe"
    [[ ! -e "$transaction_root" && ! -L "$transaction_root" ]] || safety_die "an unfinished or unsafe update transaction already exists"
    [[ ! -e "$cleanup_root" && ! -L "$cleanup_root" ]] || safety_die "a retired transaction still requires cleanup"
    [[ ! -L "$target" ]] || safety_die "installed app path is a symbolic link"
    [[ -d "${transaction_root%/*}" && ! -L "${transaction_root%/*}" ]] || safety_die "transaction parent is missing or unsafe"
    if [[ -e "$preparing_root" || -L "$preparing_root" ]]; then
        discard_abandoned_overlay_preparation "$transaction_root" "$operation" \
            || safety_die "incomplete transaction preparation could not be removed"
    fi
    /bin/mkdir "$preparing_root" || safety_die "transaction preparation directory could not be created"

    if ! /usr/bin/ditto "$source" "$next_payload"; then
        /bin/rm -rf -- "$preparing_root"
        safety_die "candidate staging failed"
    fi
    staged_tree="$(tree_fingerprint "$next_payload")" || safety_die "staged candidate fingerprint failed"
    source_tree="$(tree_fingerprint "$source")" || safety_die "candidate source fingerprint failed"
    if [[ "$staged_tree" != "$source_tree" ]]; then
        /bin/rm -rf -- "$preparing_root"
        safety_die "staged candidate differs from its verified source"
    fi

    if [[ -e "$target" ]]; then
        [[ -d "$target" && ! -L "$target" ]] || safety_die "installed app is not a real directory"
        had_previous=1
        if ! /usr/bin/ditto "$target" "$previous_payload"; then
            /bin/rm -rf -- "$preparing_root"
            safety_die "installed app snapshot failed"
        fi
        snapshot_tree="$(tree_fingerprint "$previous_payload")" || safety_die "installed app snapshot fingerprint failed"
        target_tree="$(tree_fingerprint "$target")" || safety_die "installed app fingerprint failed"
        if [[ "$snapshot_tree" != "$target_tree" ]]; then
            /bin/rm -rf -- "$preparing_root"
            safety_die "installed app snapshot is incomplete"
        fi
    fi

    local previous_tree="absent"
    local next_tree
    if [[ "$had_previous" == "1" ]]; then
        previous_tree="$(tree_fingerprint "$previous_payload")" || safety_die "installed app snapshot fingerprint failed"
    fi
    next_tree="$(tree_fingerprint "$next_payload")" || safety_die "candidate snapshot fingerprint failed"
    /usr/bin/printf \
        'FORMAT_VERSION=1\nOPERATION=%s\nHAD_PREVIOUS=%s\nPREVIOUS_TREE_SHA256=%s\nNEXT_TREE_SHA256=%s\nPHASE=prepared\n' \
        "$operation" \
        "$had_previous" \
        "$previous_tree" \
        "$next_tree" \
        >"$preparing_root/state" \
        || safety_die "transaction state could not be written"
    /bin/mv "$preparing_root" "$transaction_root" || safety_die "prepared transaction could not be committed"
}

set_transaction_phase() {
    local transaction_root="$1"
    local phase="$2"
    local temporary_state="$transaction_root/state.next"

    prepare_regular_output_path "$temporary_state" "transaction state replacement"
    if ! /usr/bin/awk -F= -v phase="$phase" '
        $1 == "PHASE" { print "PHASE=" phase; next }
        { print }
    ' "$transaction_root/state" >"$temporary_state"; then
        /bin/rm -f "$temporary_state"
        return 1
    fi
    atomic_replace_regular_file "$temporary_state" "$transaction_root/state" "transaction state" || return 1
    return 0
}

validate_transaction_state() {
    local transaction_root="$1"
    local format
    local operation
    local had_previous
    local previous_tree
    local next_tree
    local phase

    assert_manifest_keys \
        "$transaction_root/state" \
        FORMAT_VERSION \
        OPERATION \
        HAD_PREVIOUS \
        PREVIOUS_TREE_SHA256 \
        NEXT_TREE_SHA256 \
        PHASE \
        || return 1
    format="$(transaction_state_value "$transaction_root" FORMAT_VERSION)" || return 1
    operation="$(transaction_state_value "$transaction_root" OPERATION)" || return 1
    had_previous="$(transaction_state_value "$transaction_root" HAD_PREVIOUS)" || return 1
    previous_tree="$(transaction_state_value "$transaction_root" PREVIOUS_TREE_SHA256)" || return 1
    next_tree="$(transaction_state_value "$transaction_root" NEXT_TREE_SHA256)" || return 1
    phase="$(transaction_state_value "$transaction_root" PHASE)" || return 1
    [[ "$format" == "1" ]] || return 1
    case "$operation" in
        debug-install|release-install|release-rollback|sop-test) ;;
        *) return 1 ;;
    esac
    case "$had_previous" in
        1) [[ "$previous_tree" =~ ^[a-f0-9]{64}$ ]] || return 1 ;;
        0) [[ "$previous_tree" == "absent" ]] || return 1 ;;
        *) return 1 ;;
    esac
    [[ "$next_tree" =~ ^[a-f0-9]{64}$ ]] || return 1
    case "$phase" in
        prepared|overlaid|verified|registered) ;;
        *) return 1 ;;
    esac
    return 0
}

transaction_operation_matches() {
    local transaction_root="$1"
    local expected_operation="$2"
    local recorded_operation

    validate_transaction_state "$transaction_root" || return 1
    recorded_operation="$(transaction_state_value "$transaction_root" OPERATION)" || return 1
    [[ "$recorded_operation" == "$expected_operation" ]] || return 1
    return 0
}

validate_transaction_payloads() {
    local transaction_root="$1"
    local include_next="$2"
    local had_previous
    local expected_tree
    local actual_tree

    validate_transaction_state "$transaction_root" || return 1
    had_previous="$(transaction_state_value "$transaction_root" HAD_PREVIOUS)" || return 1
    if [[ "$had_previous" == "1" ]]; then
        [[ -d "$transaction_root/previous.payload" && ! -L "$transaction_root/previous.payload" ]] || return 1
        expected_tree="$(transaction_state_value "$transaction_root" PREVIOUS_TREE_SHA256)" || return 1
        actual_tree="$(tree_fingerprint "$transaction_root/previous.payload")" || return 1
        [[ "$actual_tree" == "$expected_tree" ]] || return 1
    else
        [[ ! -e "$transaction_root/previous.payload" && ! -L "$transaction_root/previous.payload" ]] || return 1
    fi
    if [[ "$include_next" == "true" ]]; then
        [[ -d "$transaction_root/next.payload" && ! -L "$transaction_root/next.payload" ]] || return 1
        expected_tree="$(transaction_state_value "$transaction_root" NEXT_TREE_SHA256)" || return 1
        actual_tree="$(tree_fingerprint "$transaction_root/next.payload")" || return 1
        [[ "$actual_tree" == "$expected_tree" ]] || return 1
    fi
    return 0
}

transaction_fail_if_requested() {
    local stage="$1"
    if [[ "${GO2CODEX_TRANSACTION_FAIL_STAGE:-}" == "$stage" ]]; then
        return 1
    fi
    return 0
}

recover_overlay_transaction() {
    local target="$1"
    local transaction_root="$2"
    local expected_operation="$3"
    local recovery_callback="$4"
    local had_previous
    local previous_payload="$transaction_root/previous.payload"
    local previous_tree
    local target_tree="absent"

    [[ -d "$transaction_root" && ! -L "$transaction_root" ]] || return 0
    if ! transaction_operation_matches "$transaction_root" "$expected_operation"; then
        echo "go2codex-transaction: transaction belongs to another or unknown operation; preserving the transaction" >&2
        return 1
    fi
    if ! validate_transaction_payloads "$transaction_root" false; then
        echo "go2codex-transaction: transaction state or previous payload is invalid; preserving the transaction" >&2
        return 1
    fi
    had_previous="$(transaction_state_value "$transaction_root" HAD_PREVIOUS)" || return 1
    case "$had_previous" in
        1)
            if [[ ! -d "$previous_payload" || -L "$previous_payload" ]]; then
                echo "go2codex-transaction: previous.payload is missing or unsafe; preserving the transaction" >&2
                return 1
            fi
            previous_tree="$(transaction_state_value "$transaction_root" PREVIOUS_TREE_SHA256)" || return 1
            if [[ -e "$target" || -L "$target" ]]; then
                [[ -d "$target" && ! -L "$target" ]] || {
                    echo "go2codex-transaction: recovery target is unsafe; preserving the transaction" >&2
                    return 1
                }
                target_tree="$(tree_fingerprint "$target")" || return 1
            fi
            if [[ "$target_tree" != "$previous_tree" ]]; then
                if ! (overlay_exact_tree "$previous_payload" "$target"); then
                    echo "go2codex-transaction: restoring previous.payload failed; preserving the transaction" >&2
                    return 1
                fi
            fi
            if ! ("$recovery_callback" "$target" true); then
                echo "go2codex-transaction: restored payload verification or registration failed; preserving the transaction" >&2
                return 1
            fi
            ;;
        0)
            if [[ -e "$target" || -L "$target" ]]; then
                if [[ ! -d "$target" || -L "$target" ]]; then
                    echo "go2codex-transaction: new-install recovery target is unsafe; preserving the transaction" >&2
                    return 1
                fi
                if ! /bin/rm -rf -- "$target"; then
                    echo "go2codex-transaction: removing the failed new installation failed; preserving the transaction" >&2
                    return 1
                fi
            fi
            if ! ("$recovery_callback" "$target" false); then
                echo "go2codex-transaction: new-install recovery verification failed; preserving the transaction" >&2
                return 1
            fi
            ;;
        *)
            echo "go2codex-transaction: transaction state has an invalid HAD_PREVIOUS value; preserving the transaction" >&2
            return 1
            ;;
    esac
    if ! retire_overlay_transaction "$transaction_root" "$expected_operation"; then
        echo "go2codex-transaction: recovered payload but could not retire the transaction directory" >&2
        return 1
    fi
}

commit_overlay_transaction() {
    local target="$1"
    local transaction_root="$2"
    local expected_operation="$3"
    local verify_callback="$4"
    local register_callback="$5"
    local recovery_callback="$6"
    local next_payload="$transaction_root/next.payload"
    local status=0
    local phase

    [[ -d "$transaction_root" && ! -L "$transaction_root" ]] || safety_die "prepared transaction is missing"
    if ! transaction_operation_matches "$transaction_root" "$expected_operation"; then
        echo "go2codex-transaction: refusing to commit a transaction owned by another or unknown operation" >&2
        return 2
    fi
    if ! validate_transaction_payloads "$transaction_root" true; then
        echo "go2codex-transaction: prepared transaction state or payload changed; preserving the transaction" >&2
        return 2
    fi
    phase="$(transaction_state_value "$transaction_root" PHASE)" || return 2
    [[ "$phase" == "prepared" ]] || safety_die "transaction is not in the prepared phase"

    if ! transaction_fail_if_requested after_prepare; then
        if ! recover_overlay_transaction "$target" "$transaction_root" "$expected_operation" "$recovery_callback"; then
            return 2
        fi
        return 1
    fi
    if ! overlay_exact_tree "$next_payload" "$target"; then
        status=1
    else
        if ! set_transaction_phase "$transaction_root" overlaid; then
            status=1
        fi
    fi
    if [[ "$status" == "0" ]] && ! transaction_fail_if_requested after_overlay; then
        status=1
    fi
    if [[ "$status" == "0" ]] && ! "$verify_callback" "$target" "$next_payload"; then
        status=1
    fi
    if [[ "$status" == "0" ]]; then
        if ! set_transaction_phase "$transaction_root" verified; then
            status=1
        fi
    fi
    if [[ "$status" == "0" ]] && ! transaction_fail_if_requested after_verify; then
        status=1
    fi
    if [[ "$status" == "0" ]] && ! "$register_callback" "$target"; then
        status=1
    fi
    if [[ "$status" == "0" ]]; then
        if ! set_transaction_phase "$transaction_root" registered; then
            status=1
        fi
    fi
    if [[ "$status" == "0" ]] && ! transaction_fail_if_requested after_register; then
        status=1
    fi

    if [[ "$status" != "0" ]]; then
        if ! recover_overlay_transaction "$target" "$transaction_root" "$expected_operation" "$recovery_callback"; then
            return 2
        fi
        return 1
    fi

    retire_overlay_transaction "$transaction_root" "$expected_operation" || return 1
    return 0
}
