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
    local readable_action_count
    local raw_action_count
    local create_action_count
    local first_tell_action
    local first_timed_action
    local normalized_block
    local expected_block

    block="$(iterm_handoff_handler_block "$path" "$handler")"
    [[ -n "$block" ]] \
        || safety_die "$kind iTerm handoff handler block is missing: $handler"
    readable_action_count="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -F -c "$readable_action" || true)"
    raw_action_count="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -E -c "$raw_action" || true)"
    create_action_count="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -E -c \
            'create (tab|window|hotkey window)( with)?|«event Itrm(ntw[NPnp]|nww[NPnp]|nhwp)»' \
            || true)"
    case "$kind" in
        source)
            [[ "$readable_action_count" == "1" && "$raw_action_count" == "0" ]] \
                || safety_die "$kind iTerm handoff handler must contain one exact single-stage target operation: $handler"
            ;;
        compiled)
            [[ $((readable_action_count + raw_action_count)) == 1 ]] \
                || safety_die "$kind iTerm handoff handler must contain one exact single-stage target operation: $handler"
            ;;
        *)
            safety_die "unknown iTerm handoff text kind: $kind"
            ;;
    esac
    [[ "$create_action_count" == "1" ]] \
        || safety_die "$kind iTerm handoff handler must create exactly one session: $handler"
    [[ "$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/grep -F -c 'commandText' || true)" == "2" ]] \
        || safety_die "$kind iTerm handoff handler must pass commandText exactly once: $handler"
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

    [[ "$first_tell_action" == "with timeout of 60 seconds" ]] \
        || safety_die "$kind iTerm handoff handler must begin with its timeout: $handler"
    case "$kind" in
        source)
            [[ "$first_timed_action" == *"$readable_action"* ]] \
                || safety_die "$kind iTerm handoff handler must create its target in one stage: $handler"
            ;;
        compiled)
            if [[ "$first_timed_action" != *"$readable_action"* ]] \
                && ! /usr/bin/printf '%s\n' "$first_timed_action" \
                    | /usr/bin/grep -E "$raw_action" >/dev/null; then
                safety_die "$kind iTerm handoff handler must create its target in one stage: $handler"
            fi
            ;;
    esac

    normalized_block="$(/usr/bin/printf '%s\n' "$block" \
        | /usr/bin/awk \
            -v kind="$kind" \
            -v readable_action="$readable_action" \
            -v raw_action="$raw_action" '
            {
                sub(/^[[:space:]]*/, "")
                sub(/[[:space:]]*$/, "")
            }
            $0 == "" { next }
            kind == "compiled" && $0 == "using terms from application \"iTerm.app\"" {
                $0 = "using terms from application \"iTerm\""
            }
            kind == "compiled" && $0 ~ ("^(" raw_action ")$") {
                $0 = readable_action
            }
            { print }
        ')"
    expected_block="$(/usr/bin/printf '%s\n' \
        "on $handler(commandText)" \
        'using terms from application "iTerm"' \
        'tell application id "com.googlecode.iterm2"' \
        'with timeout of 60 seconds' \
        "$readable_action" \
        'end timeout' \
        'end tell' \
        'end using terms from' \
        'return true' \
        "end $handler")"
    [[ "$normalized_block" == "$expected_block" ]] \
        || safety_die "$kind iTerm handoff handler must match the exact allowlisted structure: $handler"
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
    if /usr/bin/grep -E '(^|[[:space:]])delay([[:space:]]|$)|sysodela' "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must not use timing delays"
    fi
    if /usr/bin/grep -E '^[[:space:]]*launch[[:space:]]*$' "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must not rely on generic AppleScript launch"
    fi
    if /usr/bin/grep -E \
        '(^|[[:space:]])activate([[:space:]]|$)|miscactv|^[[:space:]]*(run|reopen)[[:space:]]*$' \
        "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must not activate, run, or reopen iTerm"
    fi
    if /usr/bin/grep -E \
        '(^|[[:space:]])open file([[:space:]]|$)|aevtodoc|(^|[[:space:]])write([[:space:]]|$)|Itrmsntx' \
        "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must not open files or inject text after session creation"
    fi
    if /usr/bin/grep -F -e 'quietLaunchPath' -e 'iTerm2/version.txt' "$path" >/dev/null; then
        safety_die "$kind iTerm handoff must leave quiet bootstrap to the outer adapter"
    fi

    [[ "$(iterm_handoff_text_count "$path" 'on go2codexNewWindow(commandText)')" == "1" ]] \
        || safety_die "$kind iTerm handoff is missing the exact new-window handler"
    [[ "$(iterm_handoff_text_count "$path" 'on go2codexNewTab(commandText)')" == "1" ]] \
        || safety_die "$kind iTerm handoff is missing the exact new-tab handler"
    assert_iterm_handoff_handler_contract \
        "$path" \
        "$kind" \
        go2codexNewWindow \
        'create window with default profile command commandText' \
        '«event Itrmnwwn».*«class Nwcm»:commandText'
    assert_iterm_handoff_handler_contract \
        "$path" \
        "$kind" \
        go2codexNewTab \
        'tell current window to create tab with default profile command commandText' \
        'tell «class Crwn».*«event Itrmntwn».*«class Nwcm»:commandText|«event Itrmntwn».*«class Crwn».*«class Nwcm»:commandText'
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
