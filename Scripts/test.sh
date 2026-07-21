#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
build_root="$project_dir/.build"
derived_data="$build_root/test-derived"
build_log="$build_root/test.log"
result_bundle="$build_root/test-results.xcresult"
result_summary="$build_root/test-summary.json"
release_guard=""

source "$script_dir/lib/safety.sh"

ensure_fixed_project_directory "$build_root" "$project_dir/.build" "project build directory"
assert_no_symlink_components "$derived_data" "test DerivedData"
assert_no_symlink_components "$build_log" "unit test build log"
assert_no_symlink_components "$result_bundle" "unit test result bundle"
assert_no_symlink_components "$result_summary" "unit test result summary"
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

release_guard="$(mktemp "/private/tmp/go2codex-test-release-guard.XXXXXX")" \
    || safety_die "Release guard could not be created"
create_release_guard "$release_guard" || safety_die "Release guard could not be initialized"

acquire_operation_lock "$project_dir" unit

cleanup_build_registrations "$derived_data" Debug
cleanup_all_project_build_registrations "$project_dir"
assert_no_project_build_registration "$project_dir"
"$script_dir/test-sop.sh"
"$script_dir/verify-iterm-handoff.sh"

remove_fixed_build_directory "$derived_data" "$project_dir" test-derived "test DerivedData"
remove_fixed_test_result_bundle "$result_bundle" "$project_dir"
prepare_regular_output_path "$build_log" "unit test build log"
prepare_regular_output_path "$result_summary" "unit test result summary"

/usr/bin/xcodebuild test \
    -project "$project_dir/Go2Codex.xcodeproj" \
    -scheme Go2CodexUnitTests \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    | /usr/bin/tee "$build_log"

assert_build_log_has_no_registration "$build_log"
/usr/bin/xcrun xcresulttool get test-results summary --path "$result_bundle" --compact >"$result_summary" \
    || safety_die "Xcode test result summary could not be read"
assert_test_result_summary "$result_summary" || safety_die "Xcode result bundle did not record an explicit zero-failure, zero-skip test pass"
unexpected_app="$(/usr/bin/find "$derived_data/Build/Products" -type d -name '*.app' -print -quit)"
[[ -z "$unexpected_app" ]] || safety_die "the unit-test build unexpectedly produced an app: $unexpected_app"
echo "test: unit, platform, and SOP checks passed without installing or launching an app"
