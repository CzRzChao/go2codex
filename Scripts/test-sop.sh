#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"

source "$script_dir/lib/safety.sh"
source "$script_dir/lib/overlay-transaction.sh"

test_count=0
temporary_root=""

cleanup_test_sop() {
    local status="$1"
    local cleanup_failed=0
    trap - EXIT
    trap '' INT TERM
    if [[ -n "$temporary_root" ]]; then
        /bin/rm -rf -- "$temporary_root" || cleanup_failed=1
    fi
    if [[ "$cleanup_failed" != "0" && "$status" == "0" ]]; then
        status=1
    fi
    exit "$status"
}

trap 'cleanup_test_sop "$?"' EXIT
trap 'cleanup_test_sop 130' INT
trap 'cleanup_test_sop 143' TERM

temporary_root="$(mktemp -d "/private/tmp/go2codex-sop-tests.XXXXXX")" \
    || safety_die "SOP test directory could not be created"

pass() {
    test_count=$((test_count + 1))
}

expect_failure() {
    local label="$1"
    shift
    if ("$@") >/dev/null 2>&1; then
        echo "test-sop: expected failure: $label" >&2
        exit 1
    fi
    pass
}

assert_equal_value() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "test-sop: $label: expected '$expected', got '$actual'" >&2
        exit 1
    fi
    pass
}

fixture_write() {
    local path="$1"
    local value="$2"
    /usr/bin/printf '%s\n' "$value" >"$path"
}

write_iterm_provenance() {
    local source_path="$1"
    local compiled_path="$2"
    local provenance_path="$3"
    local source_sha
    local compiled_sha

    source_sha="$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{ print $1 }')"
    compiled_sha="$(/usr/bin/shasum -a 256 "$compiled_path" | /usr/bin/awk '{ print $1 }')"
    {
        /usr/bin/printf 'FORMAT_VERSION=1\n'
        /usr/bin/printf 'SOURCE_SHA256=%s\n' "$source_sha"
        /usr/bin/printf 'COMPILED_SHA256=%s\n' "$compiled_sha"
    } >"$provenance_path"
}

iterm_gate_root="$temporary_root/iterm-handoff-gate"
iterm_gate_source="$iterm_gate_root/ITermHandoff.applescript"
iterm_gate_compiled="$iterm_gate_root/ITermHandoff.scpt"
iterm_gate_provenance="$iterm_gate_root/ITermHandoff.provenance"
/bin/mkdir "$iterm_gate_root"
/bin/cp \
    "$project_dir/Sources/Go2CodexLauncher/Resources/ITermHandoff.applescript" \
    "$iterm_gate_source"
/bin/cp \
    "$project_dir/Sources/Go2CodexLauncher/Resources/ITermHandoff.scpt" \
    "$iterm_gate_compiled"
write_iterm_provenance \
    "$iterm_gate_source" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance"
iterm_gate_tree="$(tree_fingerprint "$iterm_gate_root")"
"$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$iterm_gate_source" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance" \
    >/dev/null
pass
assert_equal_value \
    "$(tree_fingerprint "$iterm_gate_root")" \
    "$iterm_gate_tree" \
    "iTerm handoff verifier is read-only"

/usr/bin/printf '\n-- changed source\n' >>"$iterm_gate_source"
expect_failure \
    "changed iTerm handoff source" \
    "$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$iterm_gate_source" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance"
/bin/cp \
    "$project_dir/Sources/Go2CodexLauncher/Resources/ITermHandoff.applescript" \
    "$iterm_gate_source"

/usr/bin/printf 'changed' >>"$iterm_gate_compiled"
expect_failure \
    "changed iTerm handoff compiled resource" \
    "$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$iterm_gate_source" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance"
/bin/cp \
    "$project_dir/Sources/Go2CodexLauncher/Resources/ITermHandoff.scpt" \
    "$iterm_gate_compiled"

write_iterm_provenance \
    "$iterm_gate_source" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance"
/usr/bin/printf 'UNSUPPORTED=value\n' >>"$iterm_gate_provenance"
expect_failure \
    "unknown iTerm handoff provenance key" \
    "$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$iterm_gate_source" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance"

{
    /usr/bin/printf 'FORMAT_VERSION=1\n'
    /usr/bin/printf 'SOURCE_SHA256=invalid\n'
    /usr/bin/printf 'COMPILED_SHA256=%s\n' \
        "$(/usr/bin/shasum -a 256 "$iterm_gate_compiled" | /usr/bin/awk '{ print $1 }')"
} >"$iterm_gate_provenance"
expect_failure \
    "invalid iTerm handoff provenance checksum" \
    "$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$iterm_gate_source" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance"

write_iterm_provenance \
    "$iterm_gate_source" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance"
/bin/ln -s "$iterm_gate_source" "$iterm_gate_root/Linked.applescript"
expect_failure \
    "symbolic-link iTerm handoff source" \
    "$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$iterm_gate_root/Linked.applescript" \
    "$iterm_gate_compiled" \
    "$iterm_gate_provenance"
expect_failure \
    "missing iTerm handoff compiled resource" \
    "$script_dir/verify-iterm-handoff.sh" \
    --files \
    "$iterm_gate_source" \
    "$iterm_gate_root/Missing.scpt" \
    "$iterm_gate_provenance"

"$script_dir/verify-iterm-handoff.sh" >/dev/null
pass

valid_signing_config="$temporary_root/LocalSigning.conf"
{
    /usr/bin/printf 'TEAM_ID=ABCDEF1234\n'
    /usr/bin/printf 'IDENTITY_SHA1=0123456789abcdef0123456789abcdef01234567\n'
} >"$valid_signing_config"
parse_local_signing_config "$valid_signing_config"
assert_equal_value "$GO2CODEX_SIGNING_TEAM_ID" "ABCDEF1234" "valid signing team"
assert_equal_value "$GO2CODEX_SIGNING_IDENTITY_SHA1" "0123456789ABCDEF0123456789ABCDEF01234567" "normalized signing identity"

assert_equal_value "$(debug_install_signing_mode --confirm-install-debug)" "stable-local" "stable Debug confirmation mode"
assert_equal_value "$(debug_install_signing_mode --confirm-install-adhoc-debug)" "adhoc" "temporary ad-hoc Debug confirmation mode"
expect_failure "missing Debug signing confirmation" debug_install_signing_mode
expect_failure "multiple Debug signing confirmations" debug_install_signing_mode --confirm-install-debug --confirm-install-adhoc-debug
assert_debug_signing_transition stable-local stable-local
pass
assert_debug_signing_transition adhoc adhoc
pass
expect_failure "stable Debug replacement requires explicit migration" assert_debug_signing_transition stable-local adhoc
expect_failure "temporary ad-hoc cannot replace stable Debug" assert_debug_signing_transition adhoc stable-local

unknown_signing_config="$temporary_root/UnknownSigning.conf"
fixture_write "$unknown_signing_config" "UNSAFE_SETTING=value"
expect_failure "unknown signing key" parse_local_signing_config "$unknown_signing_config"

duplicate_signing_config="$temporary_root/DuplicateSigning.conf"
{
    /usr/bin/printf 'TEAM_ID=ABCDEF1234\n'
    /usr/bin/printf 'TEAM_ID=ABCDEF1234\n'
    /usr/bin/printf 'IDENTITY_SHA1=0123456789ABCDEF0123456789ABCDEF01234567\n'
} >"$duplicate_signing_config"
expect_failure "duplicate signing key" parse_local_signing_config "$duplicate_signing_config"

git_policy_project="$temporary_root/git-policy"
/bin/mkdir "$git_policy_project"
/usr/bin/git -C "$git_policy_project" init -q
expect_failure "Git repository without HEAD" git_head "$git_policy_project"
expect_failure "clean Git gate without HEAD" require_clean_git "$git_policy_project"
fixture_write "$git_policy_project/tracked" "baseline"
/usr/bin/git -C "$git_policy_project" add tracked
/usr/bin/git -C "$git_policy_project" \
    -c user.name=Go2Codex-SOP-Test \
    -c user.email=go2codex-sop-test@example.invalid \
    commit -qm baseline
require_clean_git "$git_policy_project"
pass
fixture_write "$git_policy_project/tracked" "modified"
expect_failure "dirty tracked Git file" require_clean_git "$git_policy_project"
/usr/bin/git -C "$git_policy_project" add tracked
expect_failure "staged Git file" require_clean_git "$git_policy_project"
/usr/bin/git -C "$git_policy_project" \
    -c user.name=Go2Codex-SOP-Test \
    -c user.email=go2codex-sop-test@example.invalid \
    commit -qm staged
fixture_write "$git_policy_project/untracked" "untracked"
expect_failure "untracked Git file" require_clean_git "$git_policy_project"
/bin/rm -f "$git_policy_project/untracked"
require_clean_git "$git_policy_project"
pass

unsafe_path_root="$temporary_root/path-policy"
/bin/mkdir "$unsafe_path_root"
/bin/mkdir "$unsafe_path_root/real"
/bin/ln -s "$unsafe_path_root/real" "$unsafe_path_root/link"
assert_no_symlink_components "$unsafe_path_root/real" "safe fixture"
pass
expect_failure "symbolic-link component" assert_no_symlink_components "$unsafe_path_root/link/child" "unsafe fixture"
expect_failure "wrong exact path" assert_exact_path "$unsafe_path_root/real" "$unsafe_path_root/other" "fixture"
expect_failure "relative path" assert_no_symlink_components "relative/path" "fixture"
fixture_write "$unsafe_path_root/real/protected" "unchanged"
/bin/ln -s "$unsafe_path_root/real/protected" "$unsafe_path_root/output"
expect_failure "symbolic-link output" prepare_regular_output_path "$unsafe_path_root/output" "unsafe output"
assert_equal_value "$(/bin/cat "$unsafe_path_root/real/protected")" "unchanged" "symbolic-link output preserved its target"
/bin/ln -s "$unsafe_path_root/missing" "$unsafe_path_root/dangling"
expect_failure "dangling fingerprint root" tree_fingerprint "$unsafe_path_root/dangling"

release_gate_home="$temporary_root/release-gate-home"
release_gate_project="$temporary_root/release-gate-project"
/bin/mkdir -p "$release_gate_home/Applications" "$release_gate_project/.finder-toolbar-local"
assert_no_unfinished_release_operation "$release_gate_home" "$release_gate_project"
pass
for unfinished_path in \
    "$release_gate_home/Applications/.go2codex-update" \
    "$release_gate_home/Applications/.go2codex-update.release-install.preparing" \
    "$release_gate_home/Applications/.go2codex-update.release-rollback.preparing" \
    "$release_gate_home/Applications/.go2codex-update.release-install.cleanup" \
    "$release_gate_home/Applications/.go2codex-update.release-rollback.cleanup" \
    "$release_gate_home/Applications/.go2codex-update.preparing" \
    "$release_gate_project/.finder-toolbar-local/install.pending" \
    "$release_gate_project/.finder-toolbar-local/install.pending.next" \
    "$release_gate_project/.finder-toolbar-local/rollback.pending" \
    "$release_gate_project/.finder-toolbar-local/rollback.pending.next" \
    "$release_gate_project/.finder-toolbar-local/last-rollback.manifest.next"; do
    /bin/mkdir "$unfinished_path"
    expect_failure \
        "unfinished Release evidence: ${unfinished_path##*/}" \
        assert_no_unfinished_release_operation \
        "$release_gate_home" \
        "$release_gate_project"
    /bin/rmdir "$unfinished_path"
done

smoke_gate_root="$temporary_root/smoke-gate"
/bin/mkdir "$smoke_gate_root"
assert_paths_absent "unfinished Debug smoke check" "$smoke_gate_root/pending" "$smoke_gate_root/pass.next"
pass
fixture_write "$smoke_gate_root/pending" "pending"
fixture_write "$smoke_gate_root/pass" "pass"
expect_failure \
    "passing smoke receipt with pending evidence" \
    assert_paths_absent \
    "unfinished Debug smoke check" \
    "$smoke_gate_root/pending" \
    "$smoke_gate_root/pass.next"
[[ -f "$smoke_gate_root/pass" ]] || safety_die "smoke gate changed the passing receipt"
pass

hardlink_root="$temporary_root/hardlink-output"
/bin/mkdir "$hardlink_root"
fixture_write "$hardlink_root/protected" "protected"
/bin/ln "$hardlink_root/protected" "$hardlink_root/output"
protected_inode_before="$(/usr/bin/stat -f '%i' "$hardlink_root/protected")"
prepare_regular_output_path "$hardlink_root/output" "hard-linked output"
fixture_write "$hardlink_root/output" "replacement"
assert_equal_value "$(/bin/cat "$hardlink_root/protected")" "protected" "hard-linked output preserved protected content"
assert_equal_value "$(/usr/bin/stat -f '%i' "$hardlink_root/protected")" "$protected_inode_before" "hard-linked output preserved protected inode"

fixed_build_project="$temporary_root/fixed-build-project"
/bin/mkdir -p "$fixed_build_project/.build/test-derived"
fixture_write "$fixed_build_project/.build/test-derived/value" "build output"
remove_fixed_build_directory \
    "$fixed_build_project/.build/test-derived" \
    "$fixed_build_project" \
    test-derived \
    "test fixed build directory"
[[ ! -e "$fixed_build_project/.build/test-derived" ]] || safety_die "fixed build directory was not removed"
pass
expect_failure \
    "external build directory cleanup" \
    remove_fixed_build_directory \
    "$temporary_root/outside" \
    "$fixed_build_project" \
    test-derived \
    "external build directory"
expect_failure \
    "unknown build directory cleanup" \
    remove_fixed_build_directory \
    "$fixed_build_project/.build/other" \
    "$fixed_build_project" \
    other \
    "unknown build directory"

lock_project="$temporary_root/lock-project"
/bin/mkdir "$lock_project"
acquire_operation_lock "$lock_project" product
[[ -f "$lock_project/.finder-toolbar-local/operation.lock" ]] || safety_die "operation lock was not created"
expect_failure "concurrent unit operation lock" acquire_operation_lock "$lock_project" unit
expect_failure "concurrent product operation lock" acquire_operation_lock "$lock_project" product
lock_sentinel="$lock_project/sentinel"
fixture_write "$lock_sentinel" "preserve"
if GO2CODEX_LOCK_TEST_SENTINEL="$lock_sentinel" /bin/bash -c '
    source "$1"
    trap '\''if [[ "${GO2CODEX_OPERATION_LOCK_ACTIVE:-0}" == "1" ]]; then /bin/rm -f "$GO2CODEX_LOCK_TEST_SENTINEL"; fi'\'' EXIT
    acquire_operation_lock "$2" product
' _ "$script_dir/lib/safety.sh" "$lock_project" >/dev/null 2>&1; then
    safety_die "competing operation unexpectedly acquired the lock"
fi
[[ -f "$lock_sentinel" ]] || safety_die "a lock loser ran shared cleanup"
pass
GO2CODEX_NESTED_PRODUCT_LOCK_OWNER="$$" /bin/bash -c '
    source "$1"
    acquire_operation_lock "$2" unit
    [[ "$GO2CODEX_OPERATION_LOCK_ACTIVE" == "1" ]]
    [[ "$GO2CODEX_OPERATION_LOCK_OWNED" == "0" ]]
    release_operation_lock
' _ "$script_dir/lib/safety.sh" "$lock_project"
[[ -f "$lock_project/.finder-toolbar-local/operation.lock" ]] || safety_die "nested unit operation removed the product lock"
pass
release_operation_lock
[[ ! -e "$lock_project/.finder-toolbar-local/operation.lock" ]] || safety_die "operation lock was not released"
pass
stale_lock_pid=2147483646
if /bin/kill -0 "$stale_lock_pid" 2>/dev/null; then
    safety_die "reserved stale lock test PID unexpectedly exists"
fi
fixture_write "$lock_project/.finder-toolbar-local/operation.lock" "$stale_lock_pid"
acquire_operation_lock "$lock_project" product
release_operation_lock
[[ ! -e "$lock_project/.finder-toolbar-local/operation.lock" ]] || safety_die "stale operation lock was not reclaimed"
pass

race_lock_project="$temporary_root/race-lock-project"
race_winners="$temporary_root/race-lock-winners"
race_logs="$temporary_root/race-lock-logs"
/bin/mkdir "$race_lock_project" "$race_winners" "$race_logs"
race_stale_pid=2147483646
if /bin/kill -0 "$race_stale_pid" 2>/dev/null; then
    safety_die "reserved stale lock race PID unexpectedly exists"
fi
fixture_write "$race_lock_project/.stale-pid" "$race_stale_pid"
/bin/mkdir "$race_lock_project/.finder-toolbar-local"
/bin/cp "$race_lock_project/.stale-pid" "$race_lock_project/.finder-toolbar-local/operation.lock"
/bin/sleep 2
/bin/bash -c '
    source "$1"
    acquire_operation_lock "$2" product
    /usr/bin/printf "%s\n" "$$" >"$3/one"
    /bin/sleep 2
    release_operation_lock
' _ "$script_dir/lib/safety.sh" "$race_lock_project" "$race_winners" >"$race_logs/one.log" 2>&1 &
race_first_pid=$!
/bin/bash -c '
    source "$1"
    acquire_operation_lock "$2" product
    /usr/bin/printf "%s\n" "$$" >"$3/two"
    /bin/sleep 2
    release_operation_lock
' _ "$script_dir/lib/safety.sh" "$race_lock_project" "$race_winners" >"$race_logs/two.log" 2>&1 &
race_second_pid=$!
race_first_status=0
race_second_status=0
wait "$race_first_pid" || race_first_status=$?
wait "$race_second_pid" || race_second_status=$?
race_winner_count="$(/usr/bin/find "$race_winners" -maxdepth 1 -type f -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
if [[ "$race_winner_count" != "1" ]]; then
    /bin/cat "$race_logs/one.log" "$race_logs/two.log" >&2 || true
    safety_die "stale lock race produced $race_winner_count winners (statuses $race_first_status/$race_second_status)"
fi
if [[ "$race_first_status" == "0" ]]; then
    [[ "$race_second_status" != "0" ]] || safety_die "both stale lock contenders succeeded"
else
    [[ "$race_second_status" == "0" ]] || safety_die "both stale lock contenders failed"
fi
[[ ! -e "$race_lock_project/.finder-toolbar-local/operation.lock" ]] || safety_die "stale lock race left an operation lock"
pass
expect_failure "unknown operation lock lane" acquire_operation_lock "$lock_project" unsafe

signal_fixture="$temporary_root/signal-status.sh"
/usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'cleanup() {' \
    '    local status="$1"' \
    '    trap - EXIT INT TERM' \
    '    exit "$status"' \
    '}' \
    'trap '\''cleanup "$?"'\'' EXIT' \
    'trap '\''cleanup 130'\'' INT' \
    'trap '\''cleanup 143'\'' TERM' \
    '/bin/kill "-$1" "$$"' \
    '/bin/sleep 1' \
    >"$signal_fixture"
/bin/chmod 700 "$signal_fixture"
signal_int_status=0
/bin/bash "$signal_fixture" INT >/dev/null 2>&1 || signal_int_status=$?
assert_equal_value "$signal_int_status" "130" "explicit INT status propagation"
signal_term_status=0
/bin/bash "$signal_fixture" TERM >/dev/null 2>&1 || signal_term_status=$?
assert_equal_value "$signal_term_status" "143" "explicit TERM status propagation"
old_trap_status=0
/usr/bin/grep -R -E '^trap[[:space:]]+cleanup[[:space:]]+EXIT[[:space:]]+INT[[:space:]]+TERM$' "$script_dir" >/dev/null \
    || old_trap_status=$?
[[ "$old_trap_status" == "1" ]] || safety_die "a main script still uses implicit signal status propagation"
pass

fingerprint_root="$temporary_root/fingerprint"
/bin/mkdir "$fingerprint_root"
fixture_write "$fingerprint_root/value" "before"
fingerprint_before="$(tree_fingerprint "$fingerprint_root")"
fixture_write "$fingerprint_root/value" "after"
fingerprint_after="$(tree_fingerprint "$fingerprint_root")"
[[ "$fingerprint_before" != "$fingerprint_after" ]] || safety_die "tree fingerprint did not detect a content change"
pass
assert_equal_value "$(tree_fingerprint "$temporary_root/missing")" "absent" "missing tree fingerprint"

assert_newer_build_number 2 1
pass
expect_failure "equal build number" assert_newer_build_number 1 1
expect_failure "lower build number" assert_newer_build_number 1 2
expect_failure "non-numeric build number" assert_newer_build_number one 1

manifest="$temporary_root/manifest.env"
{
    /usr/bin/printf 'FORMAT_VERSION=1\n'
    /usr/bin/printf 'TREE_SHA256=abc\n'
} >"$manifest"
assert_manifest_keys "$manifest" FORMAT_VERSION TREE_SHA256
pass
assert_equal_value "$(manifest_value "$manifest" TREE_SHA256)" "abc" "manifest read"
expect_failure "unexpected manifest key" assert_manifest_keys "$manifest" FORMAT_VERSION

rollback_window_root="$temporary_root/rollback-record-window"
/bin/mkdir "$rollback_window_root"
rollback_source_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
rollback_receipt_fixture="$rollback_window_root/last-rollback.manifest"
/usr/bin/printf \
    'FORMAT_VERSION=1\nGIT_HEAD=head\nNEW_TREE_SHA256=new\nNEW_MARKETING_VERSION=1.0.0\nNEW_BUILD_VERSION=2\nPREVIOUS_TREE_SHA256=previous\nPREVIOUS_SIGNING_MODE=stable-local\nPREVIOUS_MARKETING_VERSION=1.0.0\nPREVIOUS_BUILD_VERSION=1\nBACKUP_FILE=backup.zip\nBACKUP_SHA256=backup\nMIGRATION=0\nROLLBACK_SOURCE_SHA256=%s\nROLLED_BACK_AT=time\n' \
    "$rollback_source_sha" \
    >"$rollback_receipt_fixture"
assert_rollback_source_record \
    "$rollback_window_root/last-install.manifest" \
    "$rollback_receipt_fixture" \
    "$rollback_source_sha"
pass
expect_failure \
    "rollback receipt source mismatch after last-install removal" \
    assert_rollback_source_record \
    "$rollback_window_root/last-install.manifest" \
    "$rollback_receipt_fixture" \
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
fixture_write "$rollback_window_root/last-install.manifest" "installed receipt"
primary_install_sha="$(/usr/bin/shasum -a 256 "$rollback_window_root/last-install.manifest" | /usr/bin/awk '{ print $1 }')"
assert_rollback_source_record \
    "$rollback_window_root/last-install.manifest" \
    "$rollback_receipt_fixture" \
    "$primary_install_sha"
pass

passing_test_summary="$temporary_root/passing-test-summary.json"
/usr/bin/printf '%s\n' '{"result":"Passed","failedTests":0,"skippedTests":0,"expectedFailures":0,"passedTests":2,"totalTestCount":2}' >"$passing_test_summary"
assert_test_result_summary "$passing_test_summary"
pass
failing_test_summary="$temporary_root/failing-test-summary.json"
/usr/bin/printf '%s\n' '{"result":"Failed","failedTests":1,"skippedTests":0,"expectedFailures":0,"passedTests":1,"totalTestCount":2}' >"$failing_test_summary"
expect_failure "failed Xcode result summary" assert_test_result_summary "$failing_test_summary"
skipped_test_summary="$temporary_root/skipped-test-summary.json"
/usr/bin/printf '%s\n' '{"result":"Passed","failedTests":0,"skippedTests":1,"expectedFailures":0,"passedTests":1,"totalTestCount":2}' >"$skipped_test_summary"
expect_failure "skipped Xcode result summary" assert_test_result_summary "$skipped_test_summary"
empty_test_summary="$temporary_root/empty-test-summary.json"
/usr/bin/printf '%s\n' '{"result":"Passed","failedTests":0,"skippedTests":0,"expectedFailures":0,"passedTests":0,"totalTestCount":0}' >"$empty_test_summary"
expect_failure "empty Xcode result summary" assert_test_result_summary "$empty_test_summary"

transaction_verify() {
    local target="$1"
    local source="$2"
    local target_tree
    local source_tree
    target_tree="$(tree_fingerprint "$target")" || return 1
    source_tree="$(tree_fingerprint "$source")" || return 1
    [[ "$target_tree" == "$source_tree" ]]
}

transaction_register() {
    return 0
}

transaction_register_failure() {
    return 1
}

transaction_recovery() {
    return 0
}

transaction_recovery_failure() {
    return 1
}

transaction_verify_leading_failure() {
    /usr/bin/false || return 1
    transaction_verify "$@"
}

transaction_recovery_leading_failure() {
    /usr/bin/false || return 1
    return 0
}

make_transaction_fixture() {
    local root="$1"
    /bin/mkdir -p "$root/source/Contents/Applications/Go2CodexLauncher.app/Contents"
    /bin/mkdir -p "$root/target/Contents/Applications/Go2CodexLauncher.app/Contents"
    fixture_write "$root/source/new" "new"
    fixture_write "$root/source/Contents/Applications/Go2CodexLauncher.app/Contents/new" "new"
    fixture_write "$root/target/old" "old"
    fixture_write "$root/target/Contents/Applications/Go2CodexLauncher.app/Contents/old" "old"
    fixture_write "$root/source/same-metadata" "new"
    fixture_write "$root/target/same-metadata" "old"
    /usr/bin/touch -r "$root/source/same-metadata" "$root/target/same-metadata"
    fixture_write "$root/source/Contents/Applications/Go2CodexLauncher.app/Contents/same-metadata" "new"
    fixture_write "$root/target/Contents/Applications/Go2CodexLauncher.app/Contents/same-metadata" "old"
    /usr/bin/touch \
        -r "$root/source/Contents/Applications/Go2CodexLauncher.app/Contents/same-metadata" \
        "$root/target/Contents/Applications/Go2CodexLauncher.app/Contents/same-metadata"
}

success_root="$temporary_root/transaction-success"
make_transaction_fixture "$success_root"
target_inode_before="$(/usr/bin/stat -f '%i' "$success_root/target")"
launcher_inode_before="$(/usr/bin/stat -f '%i' "$success_root/target/Contents/Applications/Go2CodexLauncher.app")"
prepare_overlay_transaction "$success_root/source" "$success_root/target" "$success_root/transaction" sop-test
commit_overlay_transaction \
    "$success_root/target" \
    "$success_root/transaction" \
    sop-test \
    transaction_verify \
    transaction_register \
    transaction_recovery
assert_equal_value "$(tree_fingerprint "$success_root/target")" "$(tree_fingerprint "$success_root/source")" "successful overlay tree"
assert_equal_value "$(/usr/bin/stat -f '%i' "$success_root/target")" "$target_inode_before" "outer directory identity"
assert_equal_value "$(/usr/bin/stat -f '%i' "$success_root/target/Contents/Applications/Go2CodexLauncher.app")" "$launcher_inode_before" "nested Launcher directory identity"
[[ ! -e "$success_root/transaction" ]] || safety_die "successful transaction was not cleaned"
pass

cleanup_interruption_root="$temporary_root/transaction-cleanup-interruption"
make_transaction_fixture "$cleanup_interruption_root"
prepare_overlay_transaction \
    "$cleanup_interruption_root/source" \
    "$cleanup_interruption_root/target" \
    "$cleanup_interruption_root/transaction" \
    sop-test
GO2CODEX_TRANSACTION_FAIL_STAGE=cleanup_delete
cleanup_interruption_status=0
commit_overlay_transaction \
    "$cleanup_interruption_root/target" \
    "$cleanup_interruption_root/transaction" \
    sop-test \
    transaction_verify \
    transaction_register \
    transaction_recovery \
    >/dev/null 2>&1 \
    || cleanup_interruption_status=$?
unset GO2CODEX_TRANSACTION_FAIL_STAGE
assert_equal_value "$cleanup_interruption_status" "1" "retired transaction cleanup interruption status"
assert_equal_value \
    "$(tree_fingerprint "$cleanup_interruption_root/target")" \
    "$(tree_fingerprint "$cleanup_interruption_root/source")" \
    "cleanup interruption retained the verified committed target"
[[ ! -e "$cleanup_interruption_root/transaction" ]] \
    || safety_die "cleanup interruption left an ambiguous active transaction"
[[ -d "$cleanup_interruption_root/transaction.sop-test.cleanup" ]] \
    || safety_die "cleanup interruption did not leave an owned cleanup tombstone"
pass
finalize_retired_overlay_transaction "$cleanup_interruption_root/transaction" sop-test
[[ ! -e "$cleanup_interruption_root/transaction.sop-test.cleanup" ]] \
    || safety_die "retired transaction cleanup could not be resumed"
pass

preparation_interruption_root="$temporary_root/transaction-preparation-interruption"
make_transaction_fixture "$preparation_interruption_root"
preparation_target_before="$(tree_fingerprint "$preparation_interruption_root/target")"
/bin/mkdir "$preparation_interruption_root/transaction.sop-test.preparing"
fixture_write "$preparation_interruption_root/transaction.sop-test.preparing/partial" "partial"
discard_abandoned_overlay_preparation \
    "$preparation_interruption_root/transaction" \
    release-install
[[ -d "$preparation_interruption_root/transaction.sop-test.preparing" ]] \
    || safety_die "wrong operation removed another preparation"
pass
discard_abandoned_overlay_preparation \
    "$preparation_interruption_root/transaction" \
    sop-test
[[ ! -e "$preparation_interruption_root/transaction.sop-test.preparing" ]] \
    || safety_die "abandoned preparation could not be resumed"
assert_equal_value \
    "$(tree_fingerprint "$preparation_interruption_root/target")" \
    "$preparation_target_before" \
    "abandoned preparation cleanup left target unchanged"

wrong_owner_root="$temporary_root/transaction-wrong-owner"
make_transaction_fixture "$wrong_owner_root"
wrong_owner_target="$(tree_fingerprint "$wrong_owner_root/target")"
prepare_overlay_transaction \
    "$wrong_owner_root/source" \
    "$wrong_owner_root/target" \
    "$wrong_owner_root/transaction" \
    sop-test
transaction_operation_matches "$wrong_owner_root/transaction" sop-test
pass
expect_failure \
    "wrong-owner transaction match" \
    transaction_operation_matches \
    "$wrong_owner_root/transaction" \
    release-install
wrong_recovery_status=0
recover_overlay_transaction \
    "$wrong_owner_root/target" \
    "$wrong_owner_root/transaction" \
    release-install \
    transaction_recovery \
    >/dev/null 2>&1 \
    || wrong_recovery_status=$?
assert_equal_value "$wrong_recovery_status" "1" "wrong-owner recovery status"
wrong_commit_status=0
commit_overlay_transaction \
    "$wrong_owner_root/target" \
    "$wrong_owner_root/transaction" \
    release-install \
    transaction_verify \
    transaction_register \
    transaction_recovery \
    >/dev/null 2>&1 \
    || wrong_commit_status=$?
assert_equal_value "$wrong_commit_status" "2" "wrong-owner commit status"
assert_equal_value \
    "$(tree_fingerprint "$wrong_owner_root/target")" \
    "$wrong_owner_target" \
    "wrong-owner transaction left target unchanged"
[[ -d "$wrong_owner_root/transaction/previous.payload" ]] \
    || safety_die "wrong-owner operation deleted transaction evidence"
pass
recover_overlay_transaction \
    "$wrong_owner_root/target" \
    "$wrong_owner_root/transaction" \
    sop-test \
    transaction_recovery
[[ ! -e "$wrong_owner_root/transaction" ]] || safety_die "correct owner did not clean recovered transaction"
pass

verify_failure_root="$temporary_root/transaction-verify-leading-failure"
make_transaction_fixture "$verify_failure_root"
verify_failure_old="$(tree_fingerprint "$verify_failure_root/target")"
prepare_overlay_transaction "$verify_failure_root/source" "$verify_failure_root/target" "$verify_failure_root/transaction" sop-test
verify_failure_status=0
commit_overlay_transaction \
    "$verify_failure_root/target" \
    "$verify_failure_root/transaction" \
    sop-test \
    transaction_verify_leading_failure \
    transaction_register \
    transaction_recovery \
    || verify_failure_status=$?
assert_equal_value "$verify_failure_status" "1" "leading verifier failure status"
assert_equal_value "$(tree_fingerprint "$verify_failure_root/target")" "$verify_failure_old" "rollback after leading verifier failure"
[[ ! -e "$verify_failure_root/transaction" ]] || safety_die "leading verifier failure left a completed recovery transaction"
pass

tampered_next_root="$temporary_root/transaction-tampered-next"
make_transaction_fixture "$tampered_next_root"
tampered_next_old="$(tree_fingerprint "$tampered_next_root/target")"
prepare_overlay_transaction "$tampered_next_root/source" "$tampered_next_root/target" "$tampered_next_root/transaction" sop-test
fixture_write "$tampered_next_root/transaction/next.payload/new" "tampered"
tampered_next_status=0
commit_overlay_transaction \
    "$tampered_next_root/target" \
    "$tampered_next_root/transaction" \
    sop-test \
    transaction_verify \
    transaction_register \
    transaction_recovery \
    >/dev/null 2>&1 \
    || tampered_next_status=$?
assert_equal_value "$tampered_next_status" "2" "tampered next payload status"
assert_equal_value "$(tree_fingerprint "$tampered_next_root/target")" "$tampered_next_old" "tampered next payload left target unchanged"
[[ -d "$tampered_next_root/transaction" ]] || safety_die "tampered next payload deleted its transaction evidence"
pass

tampered_previous_root="$temporary_root/transaction-tampered-previous"
make_transaction_fixture "$tampered_previous_root"
tampered_previous_target="$(tree_fingerprint "$tampered_previous_root/target")"
prepare_overlay_transaction "$tampered_previous_root/source" "$tampered_previous_root/target" "$tampered_previous_root/transaction" sop-test
fixture_write "$tampered_previous_root/transaction/previous.payload/old" "tampered"
tampered_previous_status=0
recover_overlay_transaction \
    "$tampered_previous_root/target" \
    "$tampered_previous_root/transaction" \
    sop-test \
    transaction_recovery \
    >/dev/null 2>&1 \
    || tampered_previous_status=$?
assert_equal_value "$tampered_previous_status" "1" "tampered previous payload status"
assert_equal_value "$(tree_fingerprint "$tampered_previous_root/target")" "$tampered_previous_target" "tampered previous payload left target unchanged"
[[ -d "$tampered_previous_root/transaction" ]] || safety_die "tampered previous payload deleted its transaction evidence"
pass

checksum_recovery_root="$temporary_root/transaction-checksum-recovery"
make_transaction_fixture "$checksum_recovery_root"
prepare_overlay_transaction \
    "$checksum_recovery_root/source" \
    "$checksum_recovery_root/target" \
    "$checksum_recovery_root/transaction" \
    sop-test
fixture_write "$checksum_recovery_root/target/same-metadata" "new"
/usr/bin/touch \
    -r "$checksum_recovery_root/transaction/previous.payload/same-metadata" \
    "$checksum_recovery_root/target/same-metadata"
recover_overlay_transaction \
    "$checksum_recovery_root/target" \
    "$checksum_recovery_root/transaction" \
    sop-test \
    transaction_recovery
assert_equal_value \
    "$(/bin/cat "$checksum_recovery_root/target/same-metadata")" \
    "old" \
    "checksum-based recovery with equal size and mtime"
pass

leading_recovery_root="$temporary_root/transaction-leading-recovery-failure"
make_transaction_fixture "$leading_recovery_root"
leading_recovery_old="$(tree_fingerprint "$leading_recovery_root/target")"
prepare_overlay_transaction "$leading_recovery_root/source" "$leading_recovery_root/target" "$leading_recovery_root/transaction" sop-test
GO2CODEX_TRANSACTION_FAIL_STAGE=after_overlay
leading_recovery_status=0
commit_overlay_transaction \
    "$leading_recovery_root/target" \
    "$leading_recovery_root/transaction" \
    sop-test \
    transaction_verify \
    transaction_register \
    transaction_recovery_leading_failure \
    >/dev/null 2>&1 \
    || leading_recovery_status=$?
unset GO2CODEX_TRANSACTION_FAIL_STAGE
assert_equal_value "$leading_recovery_status" "2" "leading recovery callback failure status"
assert_equal_value "$(tree_fingerprint "$leading_recovery_root/target")" "$leading_recovery_old" "payload after leading recovery callback failure"
[[ -d "$leading_recovery_root/transaction" ]] || safety_die "leading recovery callback failure deleted its snapshot"
pass

for failure_stage in after_prepare after_overlay after_verify after_register; do
    failure_root="$temporary_root/transaction-$failure_stage"
    make_transaction_fixture "$failure_root"
    old_fingerprint="$(tree_fingerprint "$failure_root/target")"
    prepare_overlay_transaction "$failure_root/source" "$failure_root/target" "$failure_root/transaction" sop-test
    GO2CODEX_TRANSACTION_FAIL_STAGE="$failure_stage"
    if commit_overlay_transaction \
        "$failure_root/target" \
        "$failure_root/transaction" \
        sop-test \
        transaction_verify \
        transaction_register \
        transaction_recovery; then
        safety_die "fault injection unexpectedly succeeded: $failure_stage"
    fi
    unset GO2CODEX_TRANSACTION_FAIL_STAGE
    assert_equal_value "$(tree_fingerprint "$failure_root/target")" "$old_fingerprint" "rollback after $failure_stage"
    [[ ! -e "$failure_root/transaction" ]] || safety_die "failed transaction was not cleaned: $failure_stage"
    pass
done

register_failure_root="$temporary_root/transaction-register-failure"
make_transaction_fixture "$register_failure_root"
register_failure_old="$(tree_fingerprint "$register_failure_root/target")"
prepare_overlay_transaction "$register_failure_root/source" "$register_failure_root/target" "$register_failure_root/transaction" sop-test
if commit_overlay_transaction \
    "$register_failure_root/target" \
    "$register_failure_root/transaction" \
    sop-test \
    transaction_verify \
    transaction_register_failure \
    transaction_recovery; then
    safety_die "register callback failure unexpectedly succeeded"
fi
assert_equal_value "$(tree_fingerprint "$register_failure_root/target")" "$register_failure_old" "rollback after registration failure"

recovery_failure_root="$temporary_root/transaction-recovery-failure"
make_transaction_fixture "$recovery_failure_root"
recovery_failure_old="$(tree_fingerprint "$recovery_failure_root/target")"
prepare_overlay_transaction "$recovery_failure_root/source" "$recovery_failure_root/target" "$recovery_failure_root/transaction" sop-test
GO2CODEX_TRANSACTION_FAIL_STAGE=after_overlay
recovery_status=0
commit_overlay_transaction \
    "$recovery_failure_root/target" \
    "$recovery_failure_root/transaction" \
    sop-test \
    transaction_verify \
    transaction_register \
    transaction_recovery_failure 2>/dev/null \
    || recovery_status=$?
unset GO2CODEX_TRANSACTION_FAIL_STAGE
assert_equal_value "$recovery_status" "2" "recovery failure status"
[[ -d "$recovery_failure_root/transaction" ]] || safety_die "failed recovery deleted its only transaction snapshot"
assert_equal_value "$(tree_fingerprint "$recovery_failure_root/target")" "$recovery_failure_old" "payload after failed recovery callback"
recover_overlay_transaction \
    "$recovery_failure_root/target" \
    "$recovery_failure_root/transaction" \
    sop-test \
    transaction_recovery
[[ ! -e "$recovery_failure_root/transaction" ]] || safety_die "successful retry did not clean the transaction"
pass

new_install_root="$temporary_root/transaction-new-install"
/bin/mkdir -p "$new_install_root/source"
fixture_write "$new_install_root/source/new" "new"
prepare_overlay_transaction "$new_install_root/source" "$new_install_root/target" "$new_install_root/transaction" sop-test
GO2CODEX_TRANSACTION_FAIL_STAGE=after_overlay
if commit_overlay_transaction \
    "$new_install_root/target" \
    "$new_install_root/transaction" \
    sop-test \
    transaction_verify \
    transaction_register \
    transaction_recovery; then
    safety_die "new-install fault injection unexpectedly succeeded"
fi
unset GO2CODEX_TRANSACTION_FAIL_STAGE
[[ ! -e "$new_install_root/target" ]] || safety_die "failed new installation left a target behind"
pass

backup_name="Go2Codex-0.1.0-1-20260719.zip"
[[ "$backup_name" != *.app ]] || safety_die "backup name must never end in .app"
pass

extracted_app_root="$temporary_root/extracted-app"
/bin/mkdir -p "$extracted_app_root/previous.payload/Contents"
fixture_write "$extracted_app_root/previous.payload/Contents/value" "preserved"
extracted_app_tree="$(tree_fingerprint "$extracted_app_root/previous.payload")"
rename_extracted_app_for_verification \
    "$extracted_app_root/previous.payload" \
    "$extracted_app_root/Go2CodexDebug.app" \
    Go2CodexDebug.app \
    "extracted Debug fixture"
[[ ! -e "$extracted_app_root/previous.payload" ]] \
    || safety_die "extracted app rename left the generic payload behind"
assert_equal_value \
    "$(tree_fingerprint "$extracted_app_root/Go2CodexDebug.app")" \
    "$extracted_app_tree" \
    "extracted app rename preserved the payload tree"

invalid_extracted_app_root="$temporary_root/invalid-extracted-app"
/bin/mkdir -p "$invalid_extracted_app_root/previous.payload"
expect_failure \
    "unknown extracted app wrapper" \
    rename_extracted_app_for_verification \
    "$invalid_extracted_app_root/previous.payload" \
    "$invalid_extracted_app_root/Other.app" \
    Other.app \
    "invalid extracted app fixture"
[[ -d "$invalid_extracted_app_root/previous.payload" ]] \
    || safety_die "failed extracted app rename changed the payload"
pass

release_extracted_app_root="$temporary_root/release-extracted-app"
/bin/mkdir -p "$release_extracted_app_root/previous.payload/Contents"
fixture_write "$release_extracted_app_root/previous.payload/Contents/value" "release"
release_extracted_tree="$(tree_fingerprint "$release_extracted_app_root/previous.payload")"
rename_extracted_app_for_verification \
    "$release_extracted_app_root/previous.payload" \
    "$release_extracted_app_root/Go2Codex.app" \
    Go2Codex.app \
    "extracted Release fixture"
assert_equal_value \
    "$(tree_fingerprint "$release_extracted_app_root/Go2Codex.app")" \
    "$release_extracted_tree" \
    "Release extracted app rename preserved the payload tree"

wrong_payload_root="$temporary_root/wrong-extracted-payload"
/bin/mkdir -p "$wrong_payload_root/payload"
expect_failure \
    "unexpected extracted payload name" \
    rename_extracted_app_for_verification \
    "$wrong_payload_root/payload" \
    "$wrong_payload_root/Go2Codex.app" \
    Go2Codex.app \
    "wrong extracted payload fixture"
[[ -d "$wrong_payload_root/payload" ]] \
    || safety_die "wrong extracted payload name changed the payload"
pass

separate_destination_root="$temporary_root/separate-extracted-destination"
/bin/mkdir -p \
    "$separate_destination_root/source/previous.payload" \
    "$separate_destination_root/destination"
expect_failure \
    "separate extracted app destination" \
    rename_extracted_app_for_verification \
    "$separate_destination_root/source/previous.payload" \
    "$separate_destination_root/destination/Go2Codex.app" \
    Go2Codex.app \
    "separate extracted app fixture"
[[ -d "$separate_destination_root/source/previous.payload" ]] \
    || safety_die "separate extracted app destination changed the payload"
pass

existing_destination_root="$temporary_root/existing-extracted-destination"
/bin/mkdir -p \
    "$existing_destination_root/previous.payload" \
    "$existing_destination_root/Go2Codex.app"
fixture_write "$existing_destination_root/Go2Codex.app/value" "preserved"
expect_failure \
    "existing extracted app destination" \
    rename_extracted_app_for_verification \
    "$existing_destination_root/previous.payload" \
    "$existing_destination_root/Go2Codex.app" \
    Go2Codex.app \
    "existing extracted app fixture"
assert_equal_value \
    "$(/bin/cat "$existing_destination_root/Go2Codex.app/value")" \
    "preserved" \
    "existing extracted app destination was preserved"

fake_app="$temporary_root/Fake.app"
/bin/mkdir -p "$fake_app/Contents/Applications/Go2CodexLauncher.app"
fake_lsregister="$temporary_root/fake-lsregister"
/usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == "-f" && "$2" == *"Go2CodexLauncher.app" ]]; then exit 1; fi' \
    'exit 0' \
    >"$fake_lsregister"
/bin/chmod 700 "$fake_lsregister"
real_lsregister="$GO2CODEX_LSREGISTER"
GO2CODEX_LSREGISTER="$fake_lsregister"
expect_failure "inner registration failure" register_exact_app "$fake_app"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$fake_lsregister"
/bin/chmod 700 "$fake_lsregister"
expect_failure "Launch Services dump failure" assert_no_project_build_registration "$temporary_root"
GO2CODEX_LSREGISTER="$real_lsregister"

expect_failure "Debug install confirmation" "$script_dir/install-debug.sh"
expect_failure "Debug smoke confirmation" "$script_dir/smoke-debug.sh"
expect_failure "iTerm handoff rebuild confirmation" "$script_dir/rebuild-iterm-handoff.sh"
expect_failure "Release install confirmation" "$script_dir/install-personal.sh"
expect_failure "Release rollback confirmation" "$script_dir/rollback-personal.sh"
expect_failure "Release candidate rejects arguments" "$script_dir/build-personal.sh" --unsafe

echo "test-sop: $test_count safety checks passed"
