#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <app-bundle> [Debug|Release] [--signing adhoc|stable-local|developer-id] [--content current|compatible] [--marketing-version x.y.z] [--build-version n] [--compare comparison.app]" >&2
    echo "       $0 <app-bundle> [Debug|Release] [comparison.app]" >&2
    exit 64
fi

app_path="${1%/}"
shift
configuration=""
comparison_app_path=""
signing_mode=""
content_contract="current"
content_contract_was_set=0
marketing_version_override=""
build_version_override=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        Debug|Release)
            [[ -z "$configuration" ]] || {
                echo "verify-app: configuration was provided more than once" >&2
                exit 64
            }
            configuration="$1"
            shift
            ;;
        --signing)
            [[ $# -ge 2 && -z "$signing_mode" ]] || {
                echo "verify-app: --signing requires one value and may be used once" >&2
                exit 64
            }
            signing_mode="$2"
            shift 2
            ;;
        --compare)
            [[ $# -ge 2 && -z "$comparison_app_path" ]] || {
                echo "verify-app: --compare requires one value and may be used once" >&2
                exit 64
            }
            comparison_app_path="${2%/}"
            shift 2
            ;;
        --content)
            [[ $# -ge 2 && "$content_contract_was_set" == "0" ]] || {
                echo "verify-app: --content requires one value and may be used once" >&2
                exit 64
            }
            content_contract="$2"
            content_contract_was_set=1
            shift 2
            ;;
        --marketing-version)
            [[ $# -ge 2 && -z "$marketing_version_override" ]] || {
                echo "verify-app: --marketing-version requires one value and may be used once" >&2
                exit 64
            }
            marketing_version_override="$2"
            shift 2
            ;;
        --build-version)
            [[ $# -ge 2 && -z "$build_version_override" ]] || {
                echo "verify-app: --build-version requires one value and may be used once" >&2
                exit 64
            }
            build_version_override="$2"
            shift 2
            ;;
        --*)
            echo "verify-app: unsupported option: $1" >&2
            exit 64
            ;;
        *)
            [[ -z "$comparison_app_path" ]] || {
                echo "verify-app: comparison app was provided more than once" >&2
                exit 64
            }
            comparison_app_path="${1%/}"
            shift
            ;;
    esac
done
outer_plist="$app_path/Contents/Info.plist"
expected_marketing_version="${marketing_version_override:-$(/usr/bin/awk -F= '$1 ~ /^[[:space:]]*MARKETING_VERSION[[:space:]]*$/ { value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }' "$project_dir/Config/Base.xcconfig")}"
expected_build_version="${build_version_override:-$(/usr/bin/awk -F= '$1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*$/ { value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }' "$project_dir/Config/Base.xcconfig")}"

fail() {
    echo "verify-app: $*" >&2
    exit 1
}

temporary_directory=""

cleanup_verifier() {
    local status="$1"
    local cleanup_failed=0
    trap - EXIT
    trap '' INT TERM
    if [[ -n "$temporary_directory" ]]; then
        /bin/rm -rf -- "$temporary_directory" || cleanup_failed=1
    fi
    if [[ "$cleanup_failed" != "0" && "$status" == "0" ]]; then
        status=1
    fi
    exit "$status"
}

trap 'cleanup_verifier "$?"' EXIT
trap 'cleanup_verifier 130' INT
trap 'cleanup_verifier 143' TERM

temporary_directory="$(mktemp -d "/private/tmp/go2codex-verify.XXXXXX")" \
    || fail "temporary verification directory could not be created"

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :'$2'" "$1"
}

assert_equal() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

embedded_macho_exists() {
    local basename="$1"
    local candidate
    for candidate in "${macho_paths[@]}"; do
        [[ "${candidate##*/}" == "$basename" ]] && return 0
    done
    return 1
}

verify_macho() {
    local executable="$1"
    local label="$2"
    local architectures
    local minimum_version
    local dependency_list

    [[ -x "$executable" ]] || fail "$label executable is missing"
    architectures="$(/usr/bin/lipo -archs "$executable")"
    assert_equal "$architectures" "arm64" "$label architectures"
    minimum_version="$(xcrun vtool -show-build "$executable" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
    assert_equal "$minimum_version" "14.0" "$label minimum macOS version"

    dependency_list="$(mktemp "$temporary_directory/dependencies.XXXXXX")" || fail "$label dependency list could not be created"
    if ! /usr/bin/otool -L "$executable" | /usr/bin/awk 'NR > 1 { print $1 }' >"$dependency_list"; then
        fail "$label dependencies could not be inspected"
    fi
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/Frameworks/CFNetwork.framework/*|/System/Library/Frameworks/Network.framework/*|/System/Library/Frameworks/WebKit.framework/*|/usr/lib/libcurl*)
                fail "$label has forbidden networking dependency: $dependency"
                ;;
            /System/Library/Frameworks/*|/usr/lib/*) ;;
            @rpath/*.debug.dylib)
                [[ "$configuration" == "Debug" ]] || fail "$label has unexpected dynamic dependency: $dependency"
                embedded_macho_exists "${dependency#@rpath/}" || fail "$label references a missing debug dylib: $dependency"
                ;;
            *) fail "$label has unexpected dynamic dependency: $dependency" ;;
        esac
    done <"$dependency_list"
    /bin/rm -f "$dependency_list" || fail "$label dependency list could not be removed"
}

verify_static_runtime_contracts() {
    local executable="$1"
    local label="$2"
    local undefined_symbols
    local executable_strings
    local forbidden_pattern
    local grep_status

    forbidden_pattern='URLSession|NSURLSession|NSURLConnection|CFURLConnection|CFHTTP|CFNetwork|FoundationNetworking|NWConnection|NWListener|NWPathMonitor|WebSocket|curl_(easy|multi|global)|_(socket|connect|getaddrinfo|gethostbyname|send|sendto|recv|recvfrom)$|Sparkle|SUUpdater|SPUUpdater|Sentry|Crashlytics|FirebaseAnalytics|Analytics(Client|Event|Tracker|SDK)|Telemetry(Client|Event|SDK)|PLCrashReporter|AppCenterCrashes|crash.?upload|SMAppService|SMLoginItemSetEnabled|ServiceManagement|NSBackgroundActivityScheduler|xpc_activity_register|CocoaLumberjack|DDFileLogger|FileLogger|RollingFileLogger|LoggingSystem|Library/Logs'
    if [[ "$configuration" == "Release" ]]; then
        forbidden_pattern+='|LLVM_PROFILE_FILE|default\.profraw|__llvm_profile|__llvm_prf|__llvm_cov'
    fi

    undefined_symbols="$(/usr/bin/nm -u "$executable")" || fail "$label symbols could not be inspected"
    grep_status=0
    /usr/bin/printf '%s\n' "$undefined_symbols" | /usr/bin/grep -E -i "$forbidden_pattern" >/dev/null || grep_status=$?
    if [[ "$grep_status" == "0" ]]; then
        fail "$label references a forbidden networking, telemetry, updater, background, crash-upload, file-logging, or profiling API"
    fi
    [[ "$grep_status" == "1" ]] || fail "$label symbols could not be searched reliably"

    executable_strings="$(/usr/bin/strings -a "$executable")" || fail "$label strings could not be inspected"
    grep_status=0
    /usr/bin/printf '%s\n' "$executable_strings" | /usr/bin/grep -E -i "$forbidden_pattern|Network\.framework|CFNetwork\.framework|WebKit\.framework|libcurl|GoogleService-Info\.plist|SUFeedURL" >/dev/null || grep_status=$?
    if [[ "$grep_status" == "0" ]]; then
        fail "$label contains a forbidden networking, telemetry, updater, background, crash-upload, file-logging, or profiling marker"
    fi
    [[ "$grep_status" == "1" ]] || fail "$label strings could not be searched reliably"
}

assert_plist_key_absent() {
    local plist="$1"
    local key="$2"
    local label="$3"
    if /usr/libexec/PlistBuddy -c "Print :'$key'" "$plist" >/dev/null 2>&1; then
        fail "$label must not declare $key"
    fi
}

verify_packaged_runtime_contracts() {
    local forbidden_entry
    local plist
    local key
    local plist_list

    forbidden_entry="$(/usr/bin/find "$app_path" -mindepth 1 \( -type d \( -name LoginItems -o -name LaunchAgents -o -name LaunchDaemons -o -name XPCServices -o -name SystemExtensions \) -o -type f \( -iname '*.log' -o -iname '*.trace' -o -iname '*.crash' -o -iname '*.ips' -o -iname 'GoogleService-Info.plist' \) \) -print -quit)" \
        || fail "packaged runtime contents could not be inspected"
    [[ -z "$forbidden_entry" ]] || fail "forbidden background-service, telemetry, crash, or standalone-log content: ${forbidden_entry#"$app_path"/}"

    for plist in "$outer_plist" "$inner_plist"; do
        for key in LSBackgroundOnly SMPrivilegedExecutables NSAppTransportSecurity NSBonjourServices NSLocalNetworkUsageDescription SUFeedURL SUScheduledCheckInterval SentryDSN; do
            assert_plist_key_absent "$plist" "$key" "${plist#"$app_path"/}"
        done
    done

    plist_list="$(mktemp "$temporary_directory/plists.XXXXXX")" || fail "packaged plist list could not be created"
    /usr/bin/find "$app_path" -type f -name '*.plist' -print0 >"$plist_list" \
        || fail "packaged plist list could not be generated"
    while IFS= read -r -d '' plist; do
        /usr/bin/plutil -lint "$plist" >/dev/null || fail "packaged plist is malformed: ${plist#"$app_path"/}"
        for key in RunAtLoad KeepAlive ProgramArguments MachServices; do
            assert_plist_key_absent "$plist" "$key" "${plist#"$app_path"/}"
        done
    done <"$plist_list"
    /bin/rm -f "$plist_list" || fail "packaged plist list could not be removed"
}

verify_release_path_hygiene() {
    local packaged_file
    local packaged_file_list
    local grep_status

    [[ "$configuration" == "Release" ]] || return 0
    packaged_file_list="$(mktemp "$temporary_directory/release-files.XXXXXX")" || fail "Release file list could not be created"
    /usr/bin/find "$app_path" -type f -print0 >"$packaged_file_list" \
        || fail "Release file list could not be generated"
    while IFS= read -r -d '' packaged_file; do
        grep_status=0
        LC_ALL=C /usr/bin/grep -a -E -m 1 \
            '(/Users/[^/]+/|/private/var/folders/|/private/tmp/|(^|/)DerivedData/|/\.build/)' \
            "$packaged_file" >/dev/null || grep_status=$?
        if [[ "$grep_status" == "0" ]]; then
            fail "${packaged_file#"$app_path"/} contains a personal or machine-specific build path"
        fi
        [[ "$grep_status" == "1" ]] || fail "${packaged_file#"$app_path"/} could not be searched for machine-specific paths"
    done <"$packaged_file_list"
    /bin/rm -f "$packaged_file_list" || fail "Release file list could not be removed"
}

plist_key_count() {
    /usr/bin/plutil -p "$1" | /usr/bin/awk '/ => / { count++ } END { print count+0 }'
}

localization_list() {
    find "$1" -mindepth 1 -maxdepth 1 -type d -name '*.lproj' -exec basename {} .lproj \; \
        | /usr/bin/sort \
        | /usr/bin/paste -sd, -
}

[[ "$expected_marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "expected marketing version is invalid"
[[ "$expected_build_version" =~ ^[1-9][0-9]*$ ]] || fail "expected build version is invalid"
[[ -d "$app_path" ]] || fail "outer app does not exist: $app_path"
[[ ! -L "$app_path" ]] || fail "outer app must not be a symbolic link"
unexpected_symlink="$(/usr/bin/find "$app_path" -type l -print -quit)" || fail "application symbolic links could not be inspected"
[[ -z "$unexpected_symlink" ]] || fail "application contains a symbolic link: ${unexpected_symlink#"$app_path"/}"
current_inner_path="$app_path/Contents/Helpers/Go2CodexLauncher.app"
legacy_inner_path="$app_path/Contents/Applications/Go2CodexLauncher.app"
case "$content_contract" in
    current)
        [[ ! -e "$legacy_inner_path" && ! -L "$legacy_inner_path" ]] \
            || fail "legacy embedded Launcher location is not allowed in current products"
        inner_path="$current_inner_path"
        ;;
    compatible)
        current_inner_present=0
        legacy_inner_present=0
        if [[ -e "$current_inner_path" || -L "$current_inner_path" ]]; then
            [[ -d "$current_inner_path" && ! -L "$current_inner_path" ]] \
                || fail "current embedded Launcher location is unsafe"
            current_inner_present=1
        fi
        if [[ -e "$legacy_inner_path" || -L "$legacy_inner_path" ]]; then
            [[ -d "$legacy_inner_path" && ! -L "$legacy_inner_path" ]] \
                || fail "legacy embedded Launcher location is unsafe"
            legacy_inner_present=1
        fi
        [[ $((current_inner_present + legacy_inner_present)) == 1 ]] \
            || fail "compatible product must contain exactly one embedded Launcher"
        if [[ "$current_inner_present" == "1" ]]; then
            inner_path="$current_inner_path"
        else
            inner_path="$legacy_inner_path"
        fi
        ;;
    *) fail "content contract must be current or compatible" ;;
esac
inner_plist="$inner_path/Contents/Info.plist"
[[ -d "$inner_path" ]] || fail "embedded Launcher is missing"
[[ -f "$outer_plist" ]] || fail "outer Info.plist is missing"
[[ -f "$inner_plist" ]] || fail "Launcher Info.plist is missing"

outer_identifier="$(plist_value "$outer_plist" CFBundleIdentifier)"
if [[ -z "$configuration" ]]; then
    case "$outer_identifier" in
        io.github.czrzchao.go2codex.debug) configuration="Debug" ;;
        io.github.czrzchao.go2codex) configuration="Release" ;;
        *) fail "cannot infer configuration from $outer_identifier" ;;
    esac
fi

case "$configuration" in
    Debug)
        expected_outer_identifier="io.github.czrzchao.go2codex.debug"
        expected_inner_identifier="io.github.czrzchao.go2codex.debug.launcher"
        expected_display_name="Go2Codex Debug"
        expected_wrapper_name="Go2CodexDebug.app"
        expected_outer_bundle_name="Go2CodexDebug"
        expected_inner_bundle_name="Go2CDebugLaunch"
        expected_outer_executable_name="Go2CodexDebug"
        expected_inner_executable_name="Go2CodexLauncher"
        ;;
    Release)
        expected_outer_identifier="io.github.czrzchao.go2codex"
        expected_inner_identifier="io.github.czrzchao.go2codex.launcher"
        expected_display_name="Go2Codex"
        expected_wrapper_name="Go2Codex.app"
        expected_outer_bundle_name="Go2Codex"
        expected_inner_bundle_name="Go2CodexLauncher"
        expected_outer_executable_name="Go2Codex"
        expected_inner_executable_name="Go2CodexLauncher"
        ;;
    *) fail "configuration must be Debug or Release" ;;
esac

if [[ -z "$signing_mode" ]]; then
    signing_mode="adhoc"
fi
case "$signing_mode" in
    adhoc|stable-local|developer-id) ;;
    *) fail "signing mode must be adhoc, stable-local, or developer-id" ;;
esac
assert_equal "${app_path##*/}" "$expected_wrapper_name" "outer wrapper name"
assert_equal "$outer_identifier" "$expected_outer_identifier" "outer bundle identifier"
assert_equal "$(plist_value "$inner_plist" CFBundleIdentifier)" "$expected_inner_identifier" "Launcher bundle identifier"
assert_equal "$(plist_value "$outer_plist" CFBundleDisplayName)" "$expected_display_name" "outer display name"
assert_equal "$(plist_value "$inner_plist" CFBundleDisplayName)" "$expected_display_name" "Launcher display name"
assert_equal "$(plist_value "$outer_plist" CFBundleName)" "$expected_outer_bundle_name" "outer bundle name"
assert_equal "$(plist_value "$inner_plist" CFBundleName)" "$expected_inner_bundle_name" "Launcher bundle name"
assert_equal "$(plist_value "$outer_plist" CFBundleExecutable)" "$expected_outer_executable_name" "outer executable name"
assert_equal "$(plist_value "$inner_plist" CFBundleExecutable)" "$expected_inner_executable_name" "Launcher executable name"
assert_equal "$(plist_value "$outer_plist" Go2CodexPreferencesDomain)" "$expected_outer_identifier" "outer preferences domain"
assert_equal "$(plist_value "$inner_plist" Go2CodexPreferencesDomain)" "$expected_outer_identifier" "Launcher preferences domain"
assert_equal "$(plist_value "$outer_plist" LSMinimumSystemVersion)" "14.0" "outer minimum macOS version"
assert_equal "$(plist_value "$inner_plist" LSMinimumSystemVersion)" "14.0" "Launcher minimum macOS version"
assert_equal "$(plist_value "$inner_plist" LSUIElement)" "true" "Launcher LSUIElement"
assert_equal "$(plist_value "$outer_plist" CFBundleShortVersionString)" "$expected_marketing_version" "outer marketing version"
assert_equal "$(plist_value "$inner_plist" CFBundleShortVersionString)" "$expected_marketing_version" "Launcher marketing version"
assert_equal "$(plist_value "$outer_plist" CFBundleVersion)" "$expected_build_version" "outer build version"
assert_equal "$(plist_value "$inner_plist" CFBundleVersion)" "$expected_build_version" "Launcher build version"
assert_equal "$(plist_value "$outer_plist" CFBundleDevelopmentRegion)" "en" "outer development language"
assert_equal "$(plist_value "$inner_plist" CFBundleDevelopmentRegion)" "en" "Launcher development language"

[[ -n "$(plist_value "$outer_plist" NSAppleEventsUsageDescription)" ]] || fail "outer Apple Events usage description is missing"
[[ -n "$(plist_value "$inner_plist" NSAppleEventsUsageDescription)" ]] || fail "Launcher Apple Events usage description is missing"
assert_equal "$(plist_value "$outer_plist" NSAppleEventsUsageDescription)" "$(plist_value "$inner_plist" NSAppleEventsUsageDescription)" "Apple Events usage descriptions"

if /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$outer_plist" >/dev/null 2>&1; then
    fail "outer app must have Dock presence"
fi

outer_executable="$app_path/Contents/MacOS/$expected_outer_executable_name"
inner_executable="$inner_path/Contents/MacOS/$expected_inner_executable_name"

macho_paths=()
all_file_list="$(mktemp "$temporary_directory/all-files.XXXXXX")" || fail "application file list could not be created"
/usr/bin/find "$app_path" -type f -print0 >"$all_file_list" || fail "application file list could not be generated"
while IFS= read -r -d '' candidate; do
    candidate_file_type="$(/usr/bin/file -b "$candidate")" || fail "file type could not be inspected: ${candidate#"$app_path"/}"
    if [[ "$candidate_file_type" == *"Mach-O"* ]]; then
        macho_paths[${#macho_paths[@]}]="$candidate"
    fi
done <"$all_file_list"
/bin/rm -f "$all_file_list" || fail "application file list could not be removed"

[[ ${#macho_paths[@]} -ge 2 ]] || fail "application contains fewer than two Mach-O files"
outer_found=false
inner_found=false
for candidate in "${macho_paths[@]}"; do
    relative_path="${candidate#"$app_path"/}"
    verify_macho "$candidate" "$relative_path"
    verify_static_runtime_contracts "$candidate" "$relative_path"
    [[ "$candidate" == "$outer_executable" ]] && outer_found=true
    [[ "$candidate" == "$inner_executable" ]] && inner_found=true
done
[[ "$outer_found" == "true" ]] || fail "outer Mach-O is missing"
[[ "$inner_found" == "true" ]] || fail "Launcher Mach-O is missing"
if [[ "$configuration" == "Release" ]]; then
    assert_equal "${#macho_paths[@]}" "2" "Release Mach-O count"
fi

inner_apple_events_adapter_present=false
for candidate in "${macho_paths[@]}"; do
    undefined_symbols="$(/usr/bin/nm -u "$candidate" 2>/dev/null || true)"
    if [[ "$candidate" == "$inner_path"/* ]]; then
        if /usr/bin/printf '%s\n' "$undefined_symbols" | /usr/bin/grep -q '_OBJC_CLASS_\$_NSAppleEventDescriptor'; then
            inner_apple_events_adapter_present=true
        fi
    elif /usr/bin/printf '%s\n' "$undefined_symbols" \
        | /usr/bin/grep -E '_OBJC_CLASS_\$_NSAppleEventDescriptor|_AEDeterminePermissionToAutomateTarget|_AESend' >/dev/null; then
        fail "outer Settings bundle must not contain Apple Events sending code"
    fi
done
[[ "$inner_apple_events_adapter_present" == "true" ]] || fail "Launcher Apple Events adapter is missing"

for frameworks_path in "$app_path/Contents/Frameworks" "$inner_path/Contents/Frameworks"; do
    if [[ -d "$frameworks_path" ]]; then
        framework_entry="$(/usr/bin/find "$frameworks_path" -mindepth 1 -print -quit)" \
            || fail "embedded framework directory could not be inspected: $frameworks_path"
        [[ -z "$framework_entry" ]] || fail "unexpected embedded framework under $frameworks_path"
    fi
done

[[ -f "$app_path/Contents/Resources/AppIcon.icns" ]] || fail "outer temporary icon is missing"
[[ -f "$inner_path/Contents/Resources/AppIcon.icns" ]] || fail "Launcher temporary icon is missing"
[[ -f "$app_path/Contents/Resources/zh-Hans.lproj/Localizable.strings" ]] || fail "outer zh-Hans localization is missing"
[[ -f "$inner_path/Contents/Resources/zh-Hans.lproj/Localizable.strings" ]] || fail "Launcher zh-Hans localization is missing"
[[ -f "$app_path/Contents/Resources/en.lproj/InfoPlist.strings" ]] || fail "outer English Info.plist localization is missing"
[[ -f "$app_path/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" ]] || fail "outer zh-Hans Info.plist localization is missing"
[[ -f "$inner_path/Contents/Resources/en.lproj/InfoPlist.strings" ]] || fail "Launcher English Info.plist localization is missing"
[[ -f "$inner_path/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" ]] || fail "Launcher zh-Hans Info.plist localization is missing"
if [[ "$content_contract" == "current" ]]; then
    "$script_dir/verify-iterm-handoff.sh" >/dev/null \
        || fail "repository iTerm handoff provenance is invalid"
    iterm_script="$inner_path/Contents/Resources/ITermHandoff.scpt"
    iterm_provenance="$project_dir/Sources/Go2CodexLauncher/Resources/ITermHandoff.provenance"
    [[ -f "$iterm_script" && ! -L "$iterm_script" ]] || fail "Launcher iTerm handoff script is missing"
    expected_iterm_sha="$(/usr/bin/awk -F= '$1 == "COMPILED_SHA256" { print $2; exit }' "$iterm_provenance")"
    actual_iterm_sha="$(/usr/bin/shasum -a 256 "$iterm_script" | /usr/bin/awk '{ print $1 }')"
    assert_equal "$(/usr/bin/file -b "$iterm_script")" "AppleScript compiled" "Launcher iTerm handoff script type"
    assert_equal "$actual_iterm_sha" "$expected_iterm_sha" "Launcher iTerm handoff script checksum"
    [[ ! -e "$app_path/Contents/Resources/ITermHandoff.scpt" ]] || fail "iTerm handoff script must be packaged only in Launcher"
    [[ ! -e "$inner_path/Contents/Resources/ITermHandoff.applescript" ]] || fail "iTerm handoff source must not be packaged"
    [[ ! -e "$inner_path/Contents/Resources/ITermHandoff.provenance" ]] || fail "iTerm handoff provenance must not be packaged"
fi
assert_equal "$(localization_list "$app_path/Contents/Resources")" "en,zh-Hans" "outer packaged localizations"
assert_equal "$(localization_list "$inner_path/Contents/Resources")" "en,zh-Hans" "Launcher packaged localizations"
if [[ "$content_contract" == "current" ]]; then
    assert_equal "$(plist_key_count "$app_path/Contents/Resources/zh-Hans.lproj/Localizable.strings")" "102" "outer Simplified Chinese string count"
    assert_equal "$(plist_key_count "$inner_path/Contents/Resources/zh-Hans.lproj/Localizable.strings")" "102" "Launcher Simplified Chinese string count"
fi
for strings_file in \
    "$app_path/Contents/Resources/zh-Hans.lproj/Localizable.strings" \
    "$inner_path/Contents/Resources/zh-Hans.lproj/Localizable.strings"; do
    assert_plist_key_absent "$strings_file" "Option-click" "${strings_file#"$app_path"/}"
    assert_equal "$(plist_value "$strings_file" "Shift-click")" "Shift 点击" "Shift-click localization"
    assert_equal "$(plist_value "$strings_file" "Option-click is reserved by Finder. Use Shift-click.")" "Option 点击已被 Finder 占用，请使用 Shift 点击。" "reserved Option localization"
    assert_equal "$(plist_value "$strings_file" "Target Picker could not be shown")" "无法显示目标选择菜单" "Target Picker readiness localization"
    assert_equal "$(plist_value "$strings_file" "Try again and keep holding Shift until the menu is visible.")" "请重试，并持续按住 Shift，直到菜单稳定显示。" "Target Picker retry localization"
    assert_equal "$(plist_value "$strings_file" "The original Finder folder is no longer available")" "原 Finder 文件夹已不可用" "Finder source-folder localization"
    if [[ "$content_contract" == "current" ]]; then
        assert_equal "$(plist_value "$strings_file" "This Finder view is not a folder")" "当前 Finder 位置不是实际文件夹" "Finder virtual-view title localization"
        assert_equal "$(plist_value "$strings_file" "Open a regular folder in Finder, then try again. Smart folders such as Recents cannot be used as a workspace.")" "请先在 Finder 中打开一个普通文件夹再重试。“最近使用”等智能文件夹不能作为工作目录。" "Finder virtual-view guidance localization"
        assert_equal "$(plist_value "$strings_file" "Go2Codex could not determine whether iTerm has a window")" "Go2Codex 无法判断 iTerm 是否有窗口" "iTerm window-state title localization"
        assert_equal "$(plist_value "$strings_file" "No terminal session was opened. Try again, or choose New Window in Go2Codex Settings.")" "未打开任何终端会话。请重试，或在 Go2Codex 设置中选择“新窗口”。" "iTerm window-state guidance localization"
        assert_equal "$(plist_value "$strings_file" "Show in Finder")" "在 Finder 中显示" "manual Finder reveal localization"
        assert_equal "$(plist_value "$strings_file" "Install and Restart Finder")" "安装并重启 Finder" "automatic Finder install localization"
        assert_equal "$(plist_value "$strings_file" "Open Accessibility Settings")" "打开“辅助功能”设置" "Accessibility settings localization"
        assert_equal "$(plist_value "$strings_file" "Automation permission is required for Terminal tabs")" "Terminal 标签页需要“自动化”权限" "Terminal tab Automation localization"
        assert_equal "$(plist_value "$strings_file" "Locate Current Launcher")" "定位当前 Launcher" "current Launcher reveal localization"
        assert_equal "$(plist_value "$strings_file" "Current Launcher could not be located")" "无法定位当前 Launcher" "current Launcher fallback title localization"
    fi
done
assert_equal "$(plist_key_count "$app_path/Contents/Resources/en.lproj/InfoPlist.strings")" "1" "outer English Info.plist string count"
assert_equal "$(plist_key_count "$app_path/Contents/Resources/zh-Hans.lproj/InfoPlist.strings")" "1" "outer Simplified Chinese Info.plist string count"
assert_equal "$(plist_key_count "$inner_path/Contents/Resources/en.lproj/InfoPlist.strings")" "1" "Launcher English Info.plist string count"
assert_equal "$(plist_key_count "$inner_path/Contents/Resources/zh-Hans.lproj/InfoPlist.strings")" "1" "Launcher Simplified Chinese Info.plist string count"

verify_packaged_runtime_contracts
verify_release_path_hygiene

/usr/bin/codesign --verify --strict --all-architectures "$inner_path"
/usr/bin/codesign --verify --strict --all-architectures "$app_path"
/usr/bin/codesign --verify --deep --strict --all-architectures "$app_path"

outer_entitlements="$temporary_directory/outer-entitlements.plist"
inner_entitlements="$temporary_directory/inner-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$app_path" >"$outer_entitlements" 2>/dev/null
/usr/bin/codesign -d --entitlements :- "$inner_path" >"$inner_entitlements" 2>/dev/null
if [[ "$configuration" == "Debug" ]]; then
    assert_equal "$(plist_key_count "$outer_entitlements")" "2" "outer entitlement count"
    assert_equal "$(plist_key_count "$inner_entitlements")" "2" "Launcher entitlement count"
    assert_equal "$(plist_value "$outer_entitlements" com.apple.security.get-task-allow)" "true" "outer debug task entitlement"
    assert_equal "$(plist_value "$inner_entitlements" com.apple.security.get-task-allow)" "true" "Launcher debug task entitlement"
else
    assert_equal "$(plist_key_count "$outer_entitlements")" "1" "outer entitlement count"
    assert_equal "$(plist_key_count "$inner_entitlements")" "1" "Launcher entitlement count"
fi
assert_equal "$(plist_value "$outer_entitlements" com.apple.security.automation.apple-events)" "true" "outer responsible-code Apple Events entitlement"
assert_equal "$(plist_value "$inner_entitlements" com.apple.security.automation.apple-events)" "true" "Launcher Apple Events entitlement"

outer_signature="$(/usr/bin/codesign -dvvv "$app_path" 2>&1)"
inner_signature="$(/usr/bin/codesign -dvvv "$inner_path" 2>&1)"
outer_team_identifier="$(/usr/bin/printf '%s\n' "$outer_signature" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
inner_team_identifier="$(/usr/bin/printf '%s\n' "$inner_signature" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"

if [[ "$configuration" == "Release" || "$signing_mode" == "developer-id" ]]; then
    [[ "$outer_signature" == *"runtime"* ]] || fail "Release outer app lacks hardened runtime"
    [[ "$inner_signature" == *"runtime"* ]] || fail "Release Launcher lacks hardened runtime"
fi

case "$signing_mode" in
    adhoc)
        [[ "$outer_signature" == *"Signature=adhoc"* ]] || fail "outer app is not ad-hoc signed"
        [[ "$inner_signature" == *"Signature=adhoc"* ]] || fail "Launcher is not ad-hoc signed"
        [[ "$outer_team_identifier" == "not set" ]] || fail "ad-hoc outer app unexpectedly has a team identity"
        [[ "$inner_team_identifier" == "not set" ]] || fail "ad-hoc Launcher unexpectedly has a team identity"
        ;;
    stable-local)
        [[ "$outer_signature" != *"Signature=adhoc"* ]] || fail "stable-local outer app must not be ad-hoc signed"
        [[ "$inner_signature" != *"Signature=adhoc"* ]] || fail "stable-local Launcher must not be ad-hoc signed"
        [[ "$outer_signature" == *"Authority=Apple Development:"* ]] || fail "stable-local outer app is not signed by Apple Development"
        [[ "$inner_signature" == *"Authority=Apple Development:"* ]] || fail "stable-local Launcher is not signed by Apple Development"
        [[ -n "$outer_team_identifier" && "$outer_team_identifier" != "not set" ]] || fail "stable-local outer TeamIdentifier is missing"
        assert_equal "$inner_team_identifier" "$outer_team_identifier" "stable-local signing team"
        outer_requirement="$(/usr/bin/codesign -d -r- "$app_path" 2>&1)"
        inner_requirement="$(/usr/bin/codesign -d -r- "$inner_path" 2>&1)"
        [[ "$outer_requirement" == *"anchor apple generic"* ]] || fail "stable-local outer designated requirement lacks the Apple anchor"
        [[ "$inner_requirement" == *"anchor apple generic"* ]] || fail "stable-local Launcher designated requirement lacks the Apple anchor"
        ;;
    developer-id)
        [[ "$outer_signature" != *"Signature=adhoc"* ]] || fail "Developer ID outer app must not be ad-hoc signed"
        [[ "$inner_signature" != *"Signature=adhoc"* ]] || fail "Developer ID Launcher must not be ad-hoc signed"
        [[ "$outer_signature" == *"Authority=Developer ID Application:"* ]] || fail "outer app is not signed by Developer ID Application"
        [[ "$inner_signature" == *"Authority=Developer ID Application:"* ]] || fail "Launcher is not signed by Developer ID Application"
        [[ -n "$outer_team_identifier" && "$outer_team_identifier" != "not set" ]] || fail "Developer ID outer TeamIdentifier is missing"
        assert_equal "$inner_team_identifier" "$outer_team_identifier" "Developer ID signing team"
        ;;
esac

if [[ -n "$comparison_app_path" ]]; then
    [[ -d "$comparison_app_path" ]] || fail "comparison app does not exist: $comparison_app_path"
    "$script_dir/verify-app.sh" \
        "$comparison_app_path" \
        "$configuration" \
        --signing "$signing_mode" \
        --content "$content_contract" \
        --marketing-version "$expected_marketing_version" \
        --build-version "$expected_build_version"
    if ! /usr/bin/diff -qr "$app_path" "$comparison_app_path"; then
        fail "verified app bundles differ"
    fi
    echo "verify-app: verified app bundles have identical trees and file contents"
fi

echo "verify-app: $configuration product passed"
