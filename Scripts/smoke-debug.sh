#!/usr/bin/env bash

set -euo pipefail

mode=""
case "$*" in
    --begin) mode="begin" ;;
    --record-pass\ --confirm-smoke-passed) mode="record-pass" ;;
    *)
        echo "Usage: $0 --begin" >&2
        echo "       $0 --record-pass --confirm-smoke-passed" >&2
        exit 64
        ;;
esac

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
source "$script_dir/lib/safety.sh"

user_home="$(current_user_home)"
debug_app="$user_home/Applications/Go2CodexDebug.app"
local_state_root="$project_dir/.finder-toolbar-local"
install_manifest="$local_state_root/debug-install.manifest"
pending_manifest="$local_state_root/debug-smoke.pending"
pass_manifest="$local_state_root/debug-smoke.pass"
pending_manifest_next="$local_state_root/debug-smoke.pending.next"
pass_manifest_next="$local_state_root/debug-smoke.pass.next"
release_guard=""
assert_no_symlink_components "$pending_manifest" "Debug smoke pending record"
assert_no_symlink_components "$pass_manifest" "Debug smoke pass record"
assert_no_symlink_components "$pending_manifest_next" "Debug smoke pending staging file"
assert_no_symlink_components "$pass_manifest_next" "Debug smoke pass staging file"

cleanup() {
    local status="$1"
    local cleanup_failed=0
    trap - EXIT
    trap '' INT TERM
    set +e
    if [[ "${GO2CODEX_OPERATION_LOCK_ACTIVE:-0}" == "1" ]]; then
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

release_guard="$(mktemp "/private/tmp/go2codex-smoke-release-guard.XXXXXX")" \
    || safety_die "Release guard could not be created"
create_release_guard "$release_guard" || safety_die "Release guard could not be initialized"

acquire_operation_lock "$project_dir" product
assert_no_unfinished_release_operation "$user_home" "$project_dir"

require_clean_git "$project_dir"
current_head="$(git_head "$project_dir")"
"$script_dir/verify-app.sh" "$debug_app" Debug --signing stable-local
assert_manifest_keys \
    "$install_manifest" \
    FORMAT_VERSION \
    GIT_HEAD \
    WORKTREE_CLEAN \
    TREE_SHA256 \
    TEAM_ID \
    OUTER_REQUIREMENT_SHA256 \
    INNER_REQUIREMENT_SHA256
[[ "$(manifest_value "$install_manifest" FORMAT_VERSION)" == "1" ]] || safety_die "unsupported Debug install manifest"
[[ "$(manifest_value "$install_manifest" GIT_HEAD)" == "$current_head" ]] || safety_die "installed Debug does not match the current commit"
[[ "$(manifest_value "$install_manifest" WORKTREE_CLEAN)" == "1" ]] || safety_die "installed Debug was not built from a clean commit"
debug_tree="$(tree_fingerprint "$debug_app")"
[[ "$(manifest_value "$install_manifest" TREE_SHA256)" == "$debug_tree" ]] || safety_die "installed Debug changed after installation"
debug_team="$(team_identifier "$debug_app")"
debug_outer_requirement="$(designated_requirement_hash "$debug_app")"
debug_inner_requirement="$(designated_requirement_hash "$debug_app/Contents/Helpers/Go2CodexLauncher.app")"
[[ "$(manifest_value "$install_manifest" TEAM_ID)" == "$debug_team" ]] || safety_die "installed Debug signing team changed"
[[ "$(manifest_value "$install_manifest" OUTER_REQUIREMENT_SHA256)" == "$debug_outer_requirement" ]] || safety_die "installed Debug outer signing identity changed"
[[ "$(manifest_value "$install_manifest" INNER_REQUIREMENT_SHA256)" == "$debug_inner_requirement" ]] || safety_die "installed Debug Launcher signing identity changed"

if [[ "$mode" == "begin" ]]; then
    if [[ -e "$pass_manifest" || -L "$pass_manifest" ]]; then
        [[ -f "$pass_manifest" && ! -L "$pass_manifest" ]] || safety_die "Debug smoke pass record is unsafe"
        /bin/rm -f "$pass_manifest" || safety_die "old Debug smoke pass record could not be removed"
    fi
    started_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || safety_die "Debug smoke start time could not be recorded"
    prepare_regular_output_path "$pending_manifest_next" "Debug smoke pending staging file"
    assert_safe_regular_output_path "$pending_manifest" "Debug smoke pending record"
    /usr/bin/printf \
        'FORMAT_VERSION=1\nGIT_HEAD=%s\nDEBUG_TREE_SHA256=%s\nTEAM_ID=%s\nOUTER_REQUIREMENT_SHA256=%s\nINNER_REQUIREMENT_SHA256=%s\nCHECKLIST_VERSION=5\nSTARTED_AT=%s\n' \
        "$current_head" \
        "$debug_tree" \
        "$debug_team" \
        "$debug_outer_requirement" \
        "$debug_inner_requirement" \
        "$started_at" \
        >"$pending_manifest_next" \
        || safety_die "Debug smoke pending record could not be written"
    atomic_replace_regular_file "$pending_manifest_next" "$pending_manifest" "Debug smoke pending record" \
        || safety_die "Debug smoke pending record could not be committed"
    echo "Debug 实机检查已开始；以下 15 项必须全部可见通过："
    echo "1. 从 Applications 启动 Debug 只进入 Debug 设置，不读取 Finder、不启动目标。"
    echo "2. 普通文件夹直接点击：默认目标只启动一次，并收到准确目录。"
    echo "3. 最近使用直接点击与 Shift 点击：都显示‘不是实际文件夹’，零 Handoff、零终端。"
    echo "4. 普通文件夹 Shift 点击：Codex App、Codex CLI、Claude Desktop Code、Claude Code CLI、Cursor、Cursor CLI 六个目标顺序正确；不可用目标置灰；面板稳定；Escape/外部点击安静取消；选择只 Handoff 一次。"
    echo "5. 连续至少 5 次打开/取消并快速重复点击：无重叠面板、无重复 Handoff。"
    echo "6. Codex App 与 Claude Desktop：分别从选择器启动一次，目录准确。"
    echo "7. Cursor App：完全退出后的冷启动和已经运行时的热启动都收到准确目录；复用现有窗口或新建窗口遵循 Cursor 自身设置。"
    echo "8. Codex CLI：iTerm2 无窗口时新建窗口；有窗口时按设置新建标签/窗口且不改原标签；连续执行 5 次。"
    echo "9. Claude Code CLI：重复 iTerm2 新标签、新窗口和无现有窗口路径。"
    echo "10. Cursor CLI：确认实际运行 cursor-agent；重复 iTerm2 新标签、新窗口和无现有窗口路径。"
    echo "11. Terminal.app 无窗口恢复的干净冷启动：Codex CLI/Claude Code CLI/Cursor CLI × New Window/New Tab 都只出现一个承载命令的窗口，无额外空窗或重复提交；每种成功路径连续 5 次。"
    echo "12. Terminal.app 冷启动 New Window 恢复路径：分别在恢复既有窗口、以及既有窗口位于不同 Space 时验证。可因无法安全定向而失败；失败时不提交命令、不自动重试，可能留下一个空窗口；绝不向未定向会话重复提交或创建第二个窗口。"
    echo "13. Terminal.app 运行中：无窗口时 New Window/New Tab 各生成一个命令窗口；单窗口和多窗口时，New Window 新建独立窗口，New Tab 只新增一个承载命令的标签；Codex CLI/Claude Code CLI/Cursor CLI 各连续执行 5 次，无空标签、额外窗口或重复提交。"
    echo "14. Terminal New Tab 不请求辅助功能或 System Events；codex、claude、cursor-agent 的 command not found，以及 Terminal.app/iTerm2 Automation 拒绝和取消均不回退或重复提交；每次结束后 Launcher 退出、不常驻。"
    echo "15. 正式版文件、偏好、Automation 与 Finder 正式按钮均未被覆盖或重置。"
    echo "全部通过后运行：./Scripts/smoke-debug.sh --record-pass --confirm-smoke-passed"
else
    assert_manifest_keys \
        "$pending_manifest" \
        FORMAT_VERSION \
        GIT_HEAD \
        DEBUG_TREE_SHA256 \
        TEAM_ID \
        OUTER_REQUIREMENT_SHA256 \
        INNER_REQUIREMENT_SHA256 \
        CHECKLIST_VERSION \
        STARTED_AT
    [[ "$(manifest_value "$pending_manifest" GIT_HEAD)" == "$current_head" ]] || safety_die "the pending smoke check belongs to another commit"
    [[ "$(manifest_value "$pending_manifest" DEBUG_TREE_SHA256)" == "$debug_tree" ]] || safety_die "Debug changed during the smoke check"
    [[ "$(manifest_value "$pending_manifest" TEAM_ID)" == "$debug_team" ]] || safety_die "Debug signing team changed during the smoke check"
    [[ "$(manifest_value "$pending_manifest" OUTER_REQUIREMENT_SHA256)" == "$debug_outer_requirement" ]] || safety_die "Debug outer signing identity changed during the smoke check"
    [[ "$(manifest_value "$pending_manifest" INNER_REQUIREMENT_SHA256)" == "$debug_inner_requirement" ]] || safety_die "Debug Launcher signing identity changed during the smoke check"
    [[ "$(manifest_value "$pending_manifest" CHECKLIST_VERSION)" == "5" ]] || safety_die "the pending smoke checklist is obsolete"
    recorded_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || safety_die "Debug smoke completion time could not be recorded"
    prepare_regular_output_path "$pass_manifest_next" "Debug smoke pass staging file"
    assert_safe_regular_output_path "$pass_manifest" "Debug smoke pass record"
    /usr/bin/printf \
        'FORMAT_VERSION=1\nGIT_HEAD=%s\nDEBUG_TREE_SHA256=%s\nTEAM_ID=%s\nOUTER_REQUIREMENT_SHA256=%s\nINNER_REQUIREMENT_SHA256=%s\nCHECKLIST_VERSION=5\nRESULT=pass\nRECORDED_AT=%s\n' \
        "$current_head" \
        "$debug_tree" \
        "$debug_team" \
        "$debug_outer_requirement" \
        "$debug_inner_requirement" \
        "$recorded_at" \
        >"$pass_manifest_next" \
        || safety_die "Debug smoke pass record could not be written"
    atomic_replace_regular_file "$pass_manifest_next" "$pass_manifest" "Debug smoke pass record" \
        || safety_die "Debug smoke pass record could not be committed"
    /bin/rm -f "$pending_manifest" || safety_die "Debug smoke pending record could not be cleared"
    echo "smoke-debug: recorded a passing Debug smoke check for $current_head"
fi
