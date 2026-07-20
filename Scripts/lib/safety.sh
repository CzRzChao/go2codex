#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export LANG=C

GO2CODEX_LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
GO2CODEX_OPERATION_LOCK=""
GO2CODEX_OPERATION_LOCK_ACTIVE=0
GO2CODEX_OPERATION_LOCK_OWNED=0

safety_die() {
    echo "go2codex-safety: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || safety_die "required command is unavailable: $1"
}

current_user_home() {
    local resolved
    [[ -n "${HOME:-}" && -d "$HOME" && ! -L "$HOME" ]] || safety_die "the current user home directory is unavailable or is a symbolic link"
    resolved="$(cd "$HOME" && /bin/pwd -P)"
    [[ "$resolved" == /* && "$resolved" != "/" ]] || safety_die "the current user home directory is unsafe"
    printf '%s\n' "$resolved"
}

assert_no_symlink_components() {
    local path="$1"
    local label="$2"
    local remainder
    local component
    local current=""

    [[ "$path" == /* ]] || safety_die "$label must be an absolute path"
    remainder="${path#/}"
    while [[ -n "$remainder" ]]; do
        component="${remainder%%/*}"
        if [[ "$remainder" == */* ]]; then
            remainder="${remainder#*/}"
        else
            remainder=""
        fi
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || safety_die "$label contains an unsafe path component"
        current="$current/$component"
        [[ ! -L "$current" ]] || safety_die "$label contains a symbolic link: $current"
    done
}

assert_exact_path() {
    local actual="$1"
    local expected="$2"
    local label="$3"

    [[ -n "$actual" && "$actual" == "$expected" ]] || safety_die "$label must be exactly $expected"
    assert_no_symlink_components "$actual" "$label"
}

ensure_fixed_project_directory() {
    local path="$1"
    local expected="$2"
    local label="$3"
    local parent

    [[ "$path" == "$expected" ]] || safety_die "$label must be exactly $expected"
    parent="${path%/*}"
    [[ -d "$parent" && ! -L "$parent" ]] || safety_die "$label parent is unavailable or unsafe"
    if [[ -e "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] || safety_die "$label is not a real directory"
    else
        /bin/mkdir "$path"
    fi
    assert_no_symlink_components "$path" "$label"
}

remove_fixed_build_directory() {
    local path="$1"
    local project_dir="$2"
    local leaf="$3"
    local label="$4"
    local expected

    case "$leaf" in
        test-derived|debug-install-derived|release-candidate-derived) ;;
        *) safety_die "unknown fixed build directory: $leaf" ;;
    esac
    expected="$project_dir/.build/$leaf"
    assert_exact_path "$path" "$expected" "$label"
    if [[ -e "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] || safety_die "$label is not a real directory"
        /bin/rm -rf -- "$path"
    fi
}

remove_fixed_test_result_bundle() {
    local path="$1"
    local project_dir="$2"
    local expected="$project_dir/.build/test-results.xcresult"

    assert_exact_path "$path" "$expected" "unit test result bundle"
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] || safety_die "unit test result bundle is unsafe"
        /bin/rm -rf -- "$path" || return 1
    fi
    return 0
}

acquire_operation_lock() {
    local project_dir="$1"
    local lane="$2"
    local lock_root="$project_dir/.finder-toolbar-local"
    local lock_path
    local existing_owner=""

    case "$lane" in
        unit|product) ;;
        *) safety_die "unknown operation lock lane: $lane" ;;
    esac
    [[ -d "$project_dir" && ! -L "$project_dir" ]] || safety_die "operation lock project directory is unsafe"
    if [[ ! -e "$lock_root" ]]; then
        /bin/mkdir "$lock_root"
    fi
    [[ -d "$lock_root" && ! -L "$lock_root" ]] || safety_die "operation lock directory is unsafe"
    lock_path="$lock_root/operation.lock"
    assert_no_symlink_components "$lock_path" "operation lock"
    if /usr/bin/shlock -f "$lock_path" -p $$; then
        GO2CODEX_OPERATION_LOCK="$lock_path"
        GO2CODEX_OPERATION_LOCK_ACTIVE=1
        GO2CODEX_OPERATION_LOCK_OWNED=1
        return 0
    fi
    [[ -f "$lock_path" && ! -L "$lock_path" ]] || safety_die "operation lock is unsafe"
    existing_owner="$(/bin/cat "$lock_path" 2>/dev/null || true)"
    [[ "$existing_owner" =~ ^[1-9][0-9]*$ ]] || safety_die "operation lock is malformed"
    if /bin/kill -0 "$existing_owner" 2>/dev/null; then
        if [[ \
            "$lane" == "unit" \
            && "${GO2CODEX_NESTED_PRODUCT_LOCK_OWNER:-}" == "$existing_owner" \
            && "$PPID" == "$existing_owner" \
        ]]; then
            GO2CODEX_OPERATION_LOCK="$lock_path"
            GO2CODEX_OPERATION_LOCK_ACTIVE=1
            GO2CODEX_OPERATION_LOCK_OWNED=0
            return 0
        fi
        safety_die "another Go2Codex $lane operation is already running"
    fi
    /bin/sleep 2
    if ! /usr/bin/shlock -f "$lock_path" -p $$; then
        safety_die "another Go2Codex $lane operation acquired or retained the lock"
    fi
    GO2CODEX_OPERATION_LOCK="$lock_path"
    GO2CODEX_OPERATION_LOCK_ACTIVE=1
    GO2CODEX_OPERATION_LOCK_OWNED=1
}

assert_paths_absent() {
    local label="$1"
    local path
    shift

    for path in "$@"; do
        assert_no_symlink_components "$path" "$label"
        [[ ! -e "$path" && ! -L "$path" ]] || safety_die "$label exists: $path"
    done
    return 0
}

assert_no_unfinished_release_operation() {
    local user_home="$1"
    local project_dir="$2"
    local transaction_root="$user_home/Applications/.go2codex-update"
    local local_state_root="$project_dir/.finder-toolbar-local"

    assert_paths_absent \
        "unfinished Release operation" \
        "$transaction_root" \
        "$transaction_root.release-install.preparing" \
        "$transaction_root.release-rollback.preparing" \
        "$transaction_root.release-install.cleanup" \
        "$transaction_root.release-rollback.cleanup" \
        "$transaction_root.preparing" \
        "$local_state_root/install.pending" \
        "$local_state_root/install.pending.next" \
        "$local_state_root/rollback.pending" \
        "$local_state_root/rollback.pending.next" \
        "$local_state_root/last-rollback.manifest.next"
}

release_operation_lock() {
    local lock_path="${GO2CODEX_OPERATION_LOCK:-}"
    local owner=""

    [[ -n "$lock_path" ]] || return 0
    if [[ "${GO2CODEX_OPERATION_LOCK_OWNED:-0}" != "1" ]]; then
        GO2CODEX_OPERATION_LOCK=""
        GO2CODEX_OPERATION_LOCK_ACTIVE=0
        return 0
    fi
    [[ -f "$lock_path" && ! -L "$lock_path" ]] || return 1
    owner="$(/bin/cat "$lock_path" 2>/dev/null)" || return 1
    [[ "$owner" == "$$" ]] || return 1
    /bin/rm -f "$lock_path" || return 1
    GO2CODEX_OPERATION_LOCK=""
    GO2CODEX_OPERATION_LOCK_ACTIVE=0
    GO2CODEX_OPERATION_LOCK_OWNED=0
    return 0
}

tree_fingerprint() {
    local root="$1"
    local listing
    local sorted_listing
    local entries
    local item
    local link_target
    local mode
    local size
    local digest
    local result

    [[ ! -L "$root" ]] || safety_die "cannot fingerprint a symbolic link: $root"
    if [[ ! -e "$root" ]]; then
        printf 'absent\n'
        return 0
    fi
    [[ -d "$root" && ! -L "$root" ]] || safety_die "cannot fingerprint a non-directory or symbolic link: $root"
    listing="$(mktemp "/private/tmp/go2codex-tree-list.XXXXXX")" || return 1
    sorted_listing="$(mktemp "/private/tmp/go2codex-tree-sorted.XXXXXX")" || {
        /bin/rm -f "$listing"
        return 1
    }
    entries="$(mktemp "/private/tmp/go2codex-tree-entries.XXXXXX")" || {
        /bin/rm -f "$listing" "$sorted_listing"
        return 1
    }
    if ! (cd "$root" && /usr/bin/find . -print) >"$listing"; then
        /bin/rm -f "$listing" "$sorted_listing" "$entries"
        return 1
    fi
    if ! LC_ALL=C /usr/bin/sort "$listing" >"$sorted_listing"; then
        /bin/rm -f "$listing" "$sorted_listing" "$entries"
        return 1
    fi
    while IFS= read -r item; do
        if [[ -L "$root/${item#./}" ]]; then
            link_target="$(/bin/readlink "$root/${item#./}")" || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
            /usr/bin/printf 'L\t%s\t%s\n' "$item" "$link_target" >>"$entries" || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
        elif [[ -f "$root/${item#./}" ]]; then
            mode="$(/usr/bin/stat -f '%Lp' "$root/${item#./}")" || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
            size="$(/usr/bin/stat -f '%z' "$root/${item#./}")" || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
            digest="$(/usr/bin/shasum -a 256 "$root/${item#./}" | /usr/bin/awk '{ print $1 }')" || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
            [[ -n "$digest" ]] || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
            /usr/bin/printf 'F\t%s\t%s\t%s\t%s\n' "$item" "$mode" "$size" "$digest" >>"$entries" || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
        elif [[ -d "$root/${item#./}" ]]; then
            mode="$(/usr/bin/stat -f '%Lp' "$root/${item#./}")" || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
            /usr/bin/printf 'D\t%s\t%s\n' "$item" "$mode" >>"$entries" || {
                /bin/rm -f "$listing" "$sorted_listing" "$entries"
                return 1
            }
        else
            /bin/rm -f "$listing" "$sorted_listing" "$entries"
            return 1
        fi
    done <"$sorted_listing"
    result="$(/usr/bin/shasum -a 256 "$entries" | /usr/bin/awk '{ print $1 }')" || {
        /bin/rm -f "$listing" "$sorted_listing" "$entries"
        return 1
    }
    [[ -n "$result" ]] || {
        /bin/rm -f "$listing" "$sorted_listing" "$entries"
        return 1
    }
    /bin/rm -f "$listing" "$sorted_listing" "$entries" || return 1
    /usr/bin/printf '%s\n' "$result" || return 1
    return 0
}

assert_safe_regular_output_path() {
    local path="$1"
    local label="$2"
    local parent="${path%/*}"

    [[ "$path" == /* && "$parent" != "$path" ]] || safety_die "$label must be an absolute file path"
    [[ -d "$parent" && ! -L "$parent" ]] || safety_die "$label parent is missing or unsafe"
    assert_no_symlink_components "$path" "$label"
    if [[ -e "$path" ]]; then
        [[ -f "$path" && ! -L "$path" ]] || safety_die "$label must be a regular file"
    fi
}

prepare_regular_output_path() {
    local path="$1"
    local label="$2"

    assert_safe_regular_output_path "$path" "$label"
    if [[ -e "$path" ]]; then
        /bin/rm -f "$path" || safety_die "$label could not be replaced safely"
    fi
}

atomic_replace_regular_file() {
    local staged="$1"
    local destination="$2"
    local label="$3"

    [[ -f "$staged" && ! -L "$staged" ]] || return 1
    assert_no_symlink_components "$staged" "$label staged file"
    assert_safe_regular_output_path "$destination" "$label"
    /bin/mv -f "$staged" "$destination" || return 1
    return 0
}

rename_extracted_app_for_verification() {
    local payload="$1"
    local destination="$2"
    local expected_name="$3"
    local label="$4"
    local parent="${payload%/*}"

    case "$expected_name" in
        Go2Codex.app|Go2CodexDebug.app) ;;
        *) safety_die "$label has an unknown application name" ;;
    esac
    [[ "${payload##*/}" == "previous.payload" ]] \
        || safety_die "$label payload has an unexpected name"
    [[ "$destination" == "$parent/$expected_name" ]] \
        || safety_die "$label destination must stay beside the payload"
    assert_no_symlink_components "$payload" "$label payload"
    assert_no_symlink_components "$destination" "$label destination"
    [[ -d "$payload" && ! -L "$payload" ]] \
        || safety_die "$label payload is missing or unsafe"
    [[ ! -e "$destination" && ! -L "$destination" ]] \
        || safety_die "$label destination already exists"
    /bin/mv "$payload" "$destination" \
        || safety_die "$label payload could not be given its application name"
    [[ -d "$destination" && ! -L "$destination" ]] \
        || safety_die "$label application is missing after rename"
}

create_release_guard() {
    local output="$1"
    local user_home
    local path
    local fingerprint

    user_home="$(current_user_home)"
    : >"$output" || return 1
    for path in "/Applications/Go2Codex.app" "$user_home/Applications/Go2Codex.app"; do
        fingerprint="$(tree_fingerprint "$path")" || return 1
        /usr/bin/printf '%s\t%s\n' "$path" "$fingerprint" >>"$output" || return 1
    done
    return 0
}

assert_release_guard_unchanged() {
    local guard="$1"
    local path
    local expected
    local actual

    [[ -f "$guard" ]] || safety_die "release guard is missing"
    while IFS=$'\t' read -r path expected; do
        [[ -n "$path" && -n "$expected" ]] || safety_die "release guard is malformed"
        actual="$(tree_fingerprint "$path")" || return 1
        [[ "$actual" == "$expected" ]] || safety_die "installed Release changed unexpectedly: $path"
    done <"$guard"
    return 0
}

cleanup_build_registrations() {
    local derived_data="$1"
    local configuration="$2"
    local product_directory="$derived_data/Build/Products/$configuration"
    local outer_name
    local path

    [[ -x "$GO2CODEX_LSREGISTER" ]] || safety_die "Launch Services registration tool is unavailable"
    case "$configuration" in
        Debug) outer_name="Go2CodexDebug.app" ;;
        Release) outer_name="Go2Codex.app" ;;
        *) safety_die "unknown build configuration: $configuration" ;;
    esac

    for path in \
        "$product_directory/$outer_name/Contents/Applications/Go2CodexLauncher.app" \
        "$product_directory/$outer_name" \
        "$product_directory/Go2CodexLauncher.app" \
        "$product_directory/Go2Codex.app" \
        "$product_directory/Go2CodexDebug.app"; do
        "$GO2CODEX_LSREGISTER" -u "$path" >/dev/null 2>&1 || true
    done
}

cleanup_all_project_build_registrations() {
    local project_dir="$1"
    local dump_file
    local line
    local path
    local prefix="$project_dir/.build/"

    [[ -x "$GO2CODEX_LSREGISTER" ]] || safety_die "Launch Services registration tool is unavailable"
    dump_file="$(mktemp "/private/tmp/go2codex-ls-clean.XXXXXX")" || return 1
    if ! "$GO2CODEX_LSREGISTER" -dump >"$dump_file"; then
        /bin/rm -f "$dump_file"
        return 1
    fi
    while IFS= read -r line; do
        [[ "$line" == path:* ]] || continue
        path="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/sed -E 's/^path:[[:space:]]*//; s/[[:space:]]+\(0x[0-9a-fA-F]+\)$//')" || {
            /bin/rm -f "$dump_file"
            return 1
        }
        [[ "$path" == "$prefix"* ]] || continue
        case "$path" in
            *"/Build/Products/"*"/Go2Codex.app"|*"/Build/Products/"*"/Go2CodexDebug.app"|*"/Build/Products/"*"/Go2CodexLauncher.app"|*"/Build/Products/"*"/Go2Codex.app/Contents/Applications/Go2CodexLauncher.app"|*"/Build/Products/"*"/Go2CodexDebug.app/Contents/Applications/Go2CodexLauncher.app")
                "$GO2CODEX_LSREGISTER" -u "$path" >/dev/null 2>&1 || true
                ;;
            *)
                /bin/rm -f "$dump_file" || true
                safety_die "refusing to unregister an unexpected project build path: $path"
                ;;
        esac
    done <"$dump_file"
    /bin/rm -f "$dump_file" || return 1
    return 0
}

assert_no_project_build_registration() {
    local project_dir="$1"
    local dump_file
    local grep_status

    [[ -x "$GO2CODEX_LSREGISTER" ]] || safety_die "Launch Services registration tool is unavailable"
    dump_file="$(mktemp "/private/tmp/go2codex-ls-dump.XXXXXX")" || return 1
    if ! "$GO2CODEX_LSREGISTER" -dump >"$dump_file"; then
        /bin/rm -f "$dump_file"
        return 1
    fi
    grep_status=0
    /usr/bin/grep -F "$project_dir/.build/" "$dump_file" >/dev/null || grep_status=$?
    if [[ "$grep_status" == "0" ]]; then
        /bin/rm -f "$dump_file" || true
        safety_die "Launch Services still contains a Go2Codex build from the project .build directory"
    fi
    [[ "$grep_status" == "1" ]] || {
        /bin/rm -f "$dump_file" || true
        return 1
    }
    /bin/rm -f "$dump_file" || return 1
    return 0
}

assert_build_log_has_no_registration() {
    local build_log="$1"
    local grep_status=0

    [[ -f "$build_log" ]] || safety_die "build log is missing"
    /usr/bin/grep -E 'RegisterWithLaunchServices|lsregister[[:space:]]+-f' "$build_log" >/dev/null || grep_status=$?
    if [[ "$grep_status" == "0" ]]; then
        safety_die "the unit-test build attempted to register an application with Launch Services"
    fi
    [[ "$grep_status" == "1" ]] || return 1
    return 0
}

assert_test_result_summary() {
    local summary="$1"
    local result
    local failed
    local skipped
    local expected_failures
    local passed
    local total

    [[ -f "$summary" && ! -L "$summary" ]] || safety_die "unit test result summary is missing or unsafe"
    result="$(/usr/bin/plutil -extract result raw -o - "$summary")" || return 1
    failed="$(/usr/bin/plutil -extract failedTests raw -o - "$summary")" || return 1
    skipped="$(/usr/bin/plutil -extract skippedTests raw -o - "$summary")" || return 1
    expected_failures="$(/usr/bin/plutil -extract expectedFailures raw -o - "$summary")" || return 1
    passed="$(/usr/bin/plutil -extract passedTests raw -o - "$summary")" || return 1
    total="$(/usr/bin/plutil -extract totalTestCount raw -o - "$summary")" || return 1
    [[ "$failed" =~ ^[0-9]+$ && "$skipped" =~ ^[0-9]+$ && "$expected_failures" =~ ^[0-9]+$ ]] || return 1
    [[ "$passed" =~ ^[1-9][0-9]*$ && "$total" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$result" == "Passed" ]] || return 1
    [[ "$failed" == "0" && "$skipped" == "0" && "$expected_failures" == "0" ]] || return 1
    [[ "$passed" == "$total" ]] || return 1
    return 0
}

git_head() {
    local project_dir="$1"
    /usr/bin/git -C "$project_dir" rev-parse --verify HEAD 2>/dev/null || safety_die "a Git baseline commit is required"
}

require_clean_git() {
    local project_dir="$1"
    local status

    git_head "$project_dir" >/dev/null
    status="$(/usr/bin/git -C "$project_dir" status --porcelain --untracked-files=all)"
    [[ -z "$status" ]] || safety_die "the Git working tree must be completely clean, including untracked files"
}

xcconfig_value() {
    local file="$1"
    local key="$2"
    /usr/bin/awk -F= -v expected="$key" '
        $1 ~ "^[[:space:]]*" expected "[[:space:]]*$" {
            value=$2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$file"
}

assert_positive_integer() {
    local value="$1"
    local label="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || safety_die "$label must be a positive integer"
}

assert_newer_build_number() {
    local candidate="$1"
    local installed="$2"

    assert_positive_integer "$candidate" "candidate build number"
    if [[ -n "$installed" ]]; then
        assert_positive_integer "$installed" "installed build number"
        (( candidate > installed )) || safety_die "candidate build number must be greater than the installed build number"
    fi
}

parse_local_signing_config() {
    local config="$1"
    local line
    local key
    local value
    local team_id=""
    local identity_sha1=""

    [[ -f "$config" && ! -L "$config" ]] || safety_die "local signing configuration is missing or unsafe: $config"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || safety_die "local signing configuration contains an invalid line"
        key="${line%%=*}"
        value="${line#*=}"
        key="$(/usr/bin/printf '%s' "$key" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        value="$(/usr/bin/printf '%s' "$value" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        case "$key" in
            TEAM_ID)
                [[ -z "$team_id" ]] || safety_die "TEAM_ID appears more than once"
                team_id="$value"
                ;;
            IDENTITY_SHA1)
                [[ -z "$identity_sha1" ]] || safety_die "IDENTITY_SHA1 appears more than once"
                identity_sha1="$(/usr/bin/printf '%s' "$value" | /usr/bin/tr '[:lower:]' '[:upper:]')"
                ;;
            *) safety_die "local signing configuration contains an unsupported key: $key" ;;
        esac
    done <"$config"

    [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || safety_die "TEAM_ID must contain exactly 10 uppercase letters or digits"
    [[ "$identity_sha1" =~ ^[A-F0-9]{40}$ ]] || safety_die "IDENTITY_SHA1 must contain exactly 40 hexadecimal characters"
    GO2CODEX_SIGNING_TEAM_ID="$team_id"
    GO2CODEX_SIGNING_IDENTITY_SHA1="$identity_sha1"
}

require_apple_development_identity() {
    local config="$1"
    local identities
    local matching_line

    parse_local_signing_config "$config"
    identities="$(/usr/bin/security find-identity -v -p codesigning)"
    matching_line="$(/usr/bin/printf '%s\n' "$identities" | /usr/bin/grep -F "$GO2CODEX_SIGNING_IDENTITY_SHA1" || true)"
    [[ -n "$matching_line" ]] || safety_die "the configured signing identity is not available in Keychain"
    [[ "$matching_line" == *'"Apple Development:'* ]] || safety_die "the configured identity is not an Apple Development certificate"
    [[ "$matching_line" == *"($GO2CODEX_SIGNING_TEAM_ID)"* ]] || safety_die "the configured signing identity does not belong to TEAM_ID"
}

debug_install_signing_mode() {
    [[ $# -eq 1 ]] || return 64
    case "$1" in
        --confirm-install-debug) /usr/bin/printf 'stable-local\n' ;;
        --confirm-install-adhoc-debug) /usr/bin/printf 'adhoc\n' ;;
        *) return 64 ;;
    esac
}

assert_debug_signing_transition() {
    local requested="$1"
    local installed="$2"

    case "$requested" in
        adhoc|stable-local) ;;
        *) safety_die "unsupported requested Debug signing mode" ;;
    esac
    case "$installed" in
        adhoc|stable-local) ;;
        *) safety_die "installed Debug has an unsupported signing mode" ;;
    esac
    [[ "$requested" == "$installed" ]] \
        || safety_die "refusing to change the installed Debug signing mode without an explicit migration"
}

signature_details() {
    /usr/bin/codesign -dvvv "$1" 2>&1
}

signature_mode() {
    local details
    details="$(signature_details "$1")"
    if [[ "$details" == *"Signature=adhoc"* ]]; then
        printf 'adhoc\n'
    elif [[ "$details" == *"Authority=Apple Development:"* ]]; then
        printf 'stable-local\n'
    elif [[ "$details" == *"Authority=Developer ID Application:"* ]]; then
        printf 'developer-id\n'
    else
        printf 'unknown\n'
    fi
}

team_identifier() {
    signature_details "$1" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
}

designated_requirement_hash() {
    local requirement
    requirement="$(/usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
    [[ -n "$requirement" ]] || safety_die "designated requirement is unavailable: $1"
    /usr/bin/printf '%s' "$requirement" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

manifest_value() {
    local manifest="$1"
    local key="$2"
    local count
    local value

    [[ -f "$manifest" && ! -L "$manifest" ]] || safety_die "manifest is missing or unsafe: $manifest"
    count="$(/usr/bin/awk -F= -v expected="$key" '$1 == expected { count++ } END { print count+0 }' "$manifest")"
    [[ "$count" == "1" ]] || safety_die "manifest key is missing or duplicated: $key"
    value="$(/usr/bin/awk -F= -v expected="$key" '$1 == expected { sub(/^[^=]*=/, ""); print; exit }' "$manifest")"
    [[ -n "$value" ]] || safety_die "manifest value is empty: $key"
    printf '%s\n' "$value"
}

assert_manifest_keys() {
    local manifest="$1"
    shift
    local line
    local key
    local allowed
    local expected

    [[ -f "$manifest" && ! -L "$manifest" ]] || safety_die "manifest is missing or unsafe: $manifest"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || safety_die "manifest contains an invalid line"
        key="${line%%=*}"
        allowed=false
        for expected in "$@"; do
            if [[ "$key" == "$expected" ]]; then
                allowed=true
                break
            fi
        done
        [[ "$allowed" == "true" ]] || safety_die "manifest contains an unsupported key: $key"
    done <"$manifest"
    for expected in "$@"; do
        manifest_value "$manifest" "$expected" >/dev/null || return 1
    done
    return 0
}

assert_rollback_source_record() {
    local last_install_manifest="$1"
    local rolled_back_manifest="$2"
    local expected_sha="$3"
    local actual_sha
    local recorded_sha

    [[ "$expected_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
    assert_no_symlink_components "$last_install_manifest" "last installation record" || return 1
    assert_no_symlink_components "$rolled_back_manifest" "rollback receipt" || return 1
    if [[ -f "$last_install_manifest" && ! -L "$last_install_manifest" ]]; then
        actual_sha="$(/usr/bin/shasum -a 256 "$last_install_manifest" | /usr/bin/awk '{ print $1 }')" || return 1
        [[ "$actual_sha" == "$expected_sha" ]] || return 1
        return 0
    fi
    [[ ! -e "$last_install_manifest" && ! -L "$last_install_manifest" ]] || return 1
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
    recorded_sha="$(manifest_value "$rolled_back_manifest" ROLLBACK_SOURCE_SHA256)" || return 1
    [[ "$recorded_sha" == "$expected_sha" ]] || return 1
    return 0
}

exact_running_pids() {
    local first_executable="$1"
    local second_executable="$2"
    /bin/ps -axo pid=,comm= | /usr/bin/awk -v first="$first_executable" -v second="$second_executable" '
        $2 == first || $2 == second { print $1 }
    ' || return 1
}

terminate_exact_app_processes() {
    local outer_executable="$1"
    local inner_executable="$2"
    local pids
    local pid
    local attempt
    local remaining

    pids="$(exact_running_pids "$outer_executable" "$inner_executable")" || return 1
    [[ -z "$pids" ]] && return 0
    while IFS= read -r pid; do
        local current_executable
        [[ "$pid" =~ ^[0-9]+$ ]] || safety_die "refusing to terminate an invalid process identifier"
        current_executable="$(/bin/ps -p "$pid" -o comm= | /usr/bin/awk '{$1=$1; print}')"
        if [[ "$current_executable" != "$outer_executable" && "$current_executable" != "$inner_executable" ]]; then
            continue
        fi
        /bin/kill -TERM "$pid"
    done <<<"$pids"

    for attempt in 1 2 3 4 5; do
        remaining="$(exact_running_pids "$outer_executable" "$inner_executable")" || return 1
        [[ -z "$remaining" ]] && return 0
        /bin/sleep 1
    done
    safety_die "Go2Codex did not exit after TERM; no files were changed"
}

register_exact_app() {
    local app_path="$1"
    local inner_path="$app_path/Contents/Applications/Go2CodexLauncher.app"

    [[ -d "$app_path" && ! -L "$app_path" ]] || safety_die "cannot register a missing or symbolic-link app"
    [[ -d "$inner_path" && ! -L "$inner_path" ]] || safety_die "cannot register a missing or symbolic-link Launcher"
    "$GO2CODEX_LSREGISTER" -f "$inner_path" || return 1
    "$GO2CODEX_LSREGISTER" -f "$app_path" || return 1
    return 0
}

assert_exact_app_paths_not_registered() {
    local app_path="$1"
    local inner_path="$app_path/Contents/Applications/Go2CodexLauncher.app"
    local dump_file
    local line
    local registered_path

    dump_file="$(mktemp "/private/tmp/go2codex-ls-exact.XXXXXX")" || return 1
    if ! "$GO2CODEX_LSREGISTER" -dump >"$dump_file"; then
        /bin/rm -f "$dump_file"
        return 1
    fi
    while IFS= read -r line; do
        [[ "$line" == path:* ]] || continue
        registered_path="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/sed -E 's/^path:[[:space:]]*//; s/[[:space:]]+\(0x[0-9a-fA-F]+\)$//')" || {
            /bin/rm -f "$dump_file"
            return 1
        }
        if [[ "$registered_path" == "$app_path" || "$registered_path" == "$inner_path" ]]; then
            /bin/rm -f "$dump_file" || true
            return 1
        fi
    done <"$dump_file"
    /bin/rm -f "$dump_file" || return 1
    return 0
}

unregister_exact_app_paths() {
    local app_path="$1"
    local inner_path="$app_path/Contents/Applications/Go2CodexLauncher.app"

    "$GO2CODEX_LSREGISTER" -u "$inner_path" >/dev/null 2>&1 || true
    "$GO2CODEX_LSREGISTER" -u "$app_path" >/dev/null 2>&1 || true
    assert_exact_app_paths_not_registered "$app_path" || return 1
    return 0
}
