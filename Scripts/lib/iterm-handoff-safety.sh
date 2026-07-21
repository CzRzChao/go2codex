#!/usr/bin/env bash

set -euo pipefail

iterm_handoff_text_count() {
    local path="$1"
    local text="$2"
    /usr/bin/grep -F -c -- "$text" "$path" || true
}

iterm_handoff_handler_block() {
    local path="$1"
    local handler="$2"
    /usr/bin/awk -v handler="$handler" '
        $0 == "on " handler "(commandText)" { inside = 1 }
        inside { print }
        $0 == "end " handler { exit }
    ' "$path"
}

assert_iterm_handoff_handler_contract() {
    local path="$1"
    local kind="$2"
    local handler="$3"
    local readable_action="$4"
    local raw_action="$5"
    local block
    local readable_path_count
    local raw_path_count
    local readable_action_count
    local raw_action_count
    local path_line
    local tell_line
    local open_line
    local action_line
    local first_tell_action
    local first_timed_action

    block="$(iterm_handoff_handler_block "$path" "$handler")"
    [[ -n "$block" ]] \
        || safety_die "$kind iTerm handoff handler block is missing: $handler"
    readable_path_count="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -F -c \
            'set quietLaunchPath to (POSIX path of (path to application support from user domain)) & "iTerm2/version.txt"' \
            || true)"
    raw_path_count="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -F -c \
            'set quietLaunchPath to (POSIX path of («event earsffdr» «constant afdrasup» given «class from»:«constant fldmfldu»)) & "iTerm2/version.txt"' \
            || true)"
    readable_action_count="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -F -c "$readable_action" || true)"
    raw_action_count="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -F -c "$raw_action" || true)"
    case "$kind" in
        source)
            [[ "$readable_path_count" == "1" && "$raw_path_count" == "0" \
                && "$readable_action_count" == "1" && "$raw_action_count" == "0" ]] \
                || safety_die "$kind iTerm handoff handler must derive one exact quiet path and target operation: $handler"
            ;;
        compiled)
            [[ $((readable_path_count + raw_path_count)) == 1 \
                && $((readable_action_count + raw_action_count)) == 1 ]] \
                || safety_die "$kind iTerm handoff handler must derive one exact quiet path and target operation: $handler"
            ;;
        *)
            safety_die "unknown iTerm handoff text kind: $kind"
            ;;
    esac
    [[ "$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -E -c '^[[:space:]]*open file quietLaunchPath[[:space:]]*$' \
            || true)" == "1" ]] \
        || safety_die "$kind iTerm handoff handler must open the quiet path exactly once: $handler"

    path_line="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/awk '/set quietLaunchPath to / { print NR; exit }')"
    tell_line="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/awk '/tell application id "com.googlecode.iterm2"/ { print NR; exit }')"
    open_line="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/awk '/^[[:space:]]*open file quietLaunchPath[[:space:]]*$/ { print NR; exit }')"
    action_line="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/awk \
            -v readable="$readable_action" \
            -v raw="$raw_action" \
            'index($0, readable) || index($0, raw) { print NR; exit }')"
    first_tell_action="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/awk '
            /tell application id "com.googlecode.iterm2"/ { insideTell = 1; next }
            insideTell && $0 !~ /^[[:space:]]*$/ {
                sub(/^[[:space:]]*/, "")
                print
                exit
            }
        ')"
    first_timed_action="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/awk '
            /with timeout of 60 seconds/ { insideTimeout = 1; next }
            insideTimeout && $0 !~ /^[[:space:]]*$/ {
                sub(/^[[:space:]]*/, "")
                print
                exit
            }
        ')"

    [[ "$path_line" =~ ^[0-9]+$ && "$tell_line" =~ ^[0-9]+$ \
        && "$open_line" =~ ^[0-9]+$ && "$action_line" =~ ^[0-9]+$ \
        && "$path_line" -lt "$tell_line" \
        && "$tell_line" -lt "$open_line" \
        && "$open_line" -lt "$action_line" \
        && "$first_tell_action" == "with timeout of 60 seconds" \
        && "$first_timed_action" == "open file quietLaunchPath" ]] \
        || safety_die "$kind iTerm handoff handler must open its exact quiet path before its first target operation: $handler"
}

assert_iterm_handoff_text_contract() {
    local path="$1"
    local kind="$2"
    local close_pattern='(^|[[:space:]])close([[:space:]]|$)'

    [[ -f "$path" && ! -L "$path" ]] \
        || safety_die "$kind iTerm handoff text is missing or unsafe"
    if [[ "$kind" == "compiled" ]]; then
        close_pattern="$close_pattern|coreclos"
    fi
    if /usr/bin/grep -E "$close_pattern" "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must not close a session after an uncertain failure"
    fi
    if /usr/bin/grep -E '(^|[[:space:]])delay([[:space:]]|$)' "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must not use timing delays"
    fi
    if /usr/bin/grep -E '^[[:space:]]*launch[[:space:]]*$' "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must not rely on generic AppleScript launch"
    fi
    if /usr/bin/grep -E '^[[:space:]]*(activate|run|reopen)[[:space:]]*$' "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must not activate, run, or reopen iTerm"
    fi

    [[ "$(iterm_handoff_text_count "$path" 'on go2codexNewWindow(commandText)')" == "1" ]] \
        || safety_die "$kind iTerm handoff is missing the exact new-window handler"
    [[ "$(iterm_handoff_text_count "$path" 'on go2codexNewTab(commandText)')" == "1" ]] \
        || safety_die "$kind iTerm handoff is missing the exact new-tab handler"
    [[ "$(iterm_handoff_text_count "$path" 'open file quietLaunchPath')" == "2" ]] \
        || safety_die "$kind iTerm handoff must quiet-open iTerm once per handler"
    assert_iterm_handoff_handler_contract \
        "$path" \
        "$kind" \
        go2codexNewWindow \
        'set createdWindow to create window with default profile' \
        'set createdWindow to «event Itrmnwwn»'
    assert_iterm_handoff_handler_contract \
        "$path" \
        "$kind" \
        go2codexNewTab \
        'set targetWindow to current window' \
        'set targetWindow to «class Crwn»'
    [[ "$(iterm_handoff_text_count "$path" 'with timeout of 60 seconds')" == "2" ]] \
        || safety_die "$kind iTerm handoff must contain two 60-second timeouts"
    [[ "$(iterm_handoff_text_count "$path" 'return true')" == "2" ]] \
        || safety_die "$kind iTerm handoff must contain two explicit success results"
}

assert_iterm_handoff_source_contract() {
    assert_iterm_handoff_text_contract "$1" source
}

assert_iterm_handoff_decompiled_contract() {
    assert_iterm_handoff_text_contract "$1" compiled
}
