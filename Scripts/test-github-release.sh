#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
package_script="$script_dir/package-github-release.sh"
workflow="$project_dir/.github/workflows/release.yml"
ci_workflow="$project_dir/.github/workflows/ci.yml"
handoff_platform="$project_dir/Sources/Go2CodexLauncher/HandoffPlatform.swift"
launcher_runtime="$project_dir/Sources/Go2CodexLauncher/LauncherRuntime.swift"
test_count=0

pass() {
    test_count=$((test_count + 1))
}

fail() {
    echo "test-github-release: $*" >&2
    exit 1
}

expect_failure() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "expected failure: $label"
    fi
    pass
}

assert_contains() {
    local file="$1"
    local expected="$2"
    local label="$3"
    /usr/bin/grep -F -- "$expected" "$file" >/dev/null \
        || fail "$label: missing '$expected'"
    pass
}

assert_count() {
    local file="$1"
    local expected="$2"
    local expected_count="$3"
    local label="$4"
    local actual_count
    actual_count="$(/usr/bin/grep -F -c -- "$expected" "$file" || true)"
    [[ "$actual_count" == "$expected_count" ]] \
        || fail "$label: expected $expected_count occurrences of '$expected', found $actual_count"
    pass
}

workflow_step() {
    local step_name="$1"
    /usr/bin/awk -v header="      - name: $step_name" '
        $0 == header {
            printing = 1
        }
        printing && $0 ~ /^      - name: / && $0 != header {
            exit
        }
        printing {
            print
        }
    ' "$workflow"
}

marketing_version="$(/usr/bin/awk -F= '
    $1 ~ /^[[:space:]]*MARKETING_VERSION[[:space:]]*$/ {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
    }
' "$project_dir/Config/Base.xcconfig")"
build_version="$(/usr/bin/awk -F= '
    $1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*$/ {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
    }
' "$project_dir/Config/Base.xcconfig")"
tag="v${marketing_version}-preview.${build_version}"
expected_contract="$(/usr/bin/printf \
    'release_tag=%s\nrelease_version=%s-preview.%s\nrelease_channel=preview\narchive_path=dist/Go2Codex-%s-preview.%s-macos-arm64.zip\nchecksum_path=dist/Go2Codex-%s-preview.%s-macos-arm64.zip.sha256' \
    "$tag" \
    "$marketing_version" \
    "$build_version" \
    "$marketing_version" \
    "$build_version" \
    "$marketing_version" \
    "$build_version")"
actual_contract="$("$package_script" --validate-only "$tag")"
[[ "$actual_contract" == "$expected_contract" ]] \
    || fail "valid preview contract output changed"
pass

stable_tag="v${marketing_version}"
expected_stable_contract="$(/usr/bin/printf \
    'release_tag=%s\nrelease_version=%s\nrelease_channel=stable\narchive_path=dist/Go2Codex-%s-macos-arm64.zip\nchecksum_path=dist/Go2Codex-%s-macos-arm64.zip.sha256' \
    "$stable_tag" \
    "$marketing_version" \
    "$marketing_version" \
    "$marketing_version")"
actual_stable_contract="$("$package_script" --validate-only "$stable_tag")"
[[ "$actual_stable_contract" == "$expected_stable_contract" ]] \
    || fail "valid stable contract output changed"
pass

expect_failure "stable tag version must match the bundle version" \
    "$package_script" --validate-only "v99.99.99"
expect_failure "stable tag must use major.minor.patch form" \
    "$package_script" --validate-only "v${marketing_version}.0"
expect_failure "preview number must be positive" \
    "$package_script" --validate-only "v${marketing_version}-preview.0"
expect_failure "preview number must not have a leading zero" \
    "$package_script" --validate-only "v${marketing_version}-preview.01"
expect_failure "tag version must match the bundle version" \
    "$package_script" --validate-only "v99.99.99-preview.1"
expect_failure "preview number must match the bundle build number" \
    "$package_script" --validate-only "v${marketing_version}-preview.999999"
expect_failure "extra arguments are rejected" \
    "$package_script" --validate-only "$tag" extra

assert_contains "$workflow" '      - "v*-preview.*"' "workflow preview-tag filter"
assert_contains "$workflow" '      - "v*.*.*"' "workflow stable-tag filter"
assert_contains "$workflow" "./Scripts/package-github-release.sh \"\$GITHUB_REF_NAME\"" "workflow package command"
assert_contains "$workflow" 'git merge-base --is-ancestor "$GITHUB_SHA" origin/main' "workflow main ancestry gate"
assert_contains "$workflow" 'uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' "workflow immutable checkout action"
assert_contains "$workflow" "persist-credentials: false" "workflow checkout credential cleanup"
assert_contains "$workflow" '"refs/tags/${GITHUB_REF_NAME}:${remote_tag_ref}"' "workflow remote-tag refresh"
assert_contains "$workflow" '"refs/heads/main:${remote_main_ref}"' "workflow remote-main refresh"
assert_contains "$workflow" 'event_commit="$(git rev-parse --verify "${GITHUB_SHA}^{commit}")"' "workflow event commit normalization"
assert_contains "$workflow" '[[ "$remote_tag_commit" == "$event_commit" ]]' "workflow remote-tag commit gate"
assert_contains "$workflow" 'git merge-base --is-ancestor "$remote_tag_commit" "$remote_main_ref"' "workflow final main ancestry gate"
assert_contains "$workflow" "./Scripts/test-sop.sh" "workflow SOP safety gate"
assert_contains "$workflow" "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" "workflow unit warning gate"
assert_contains "$workflow" "steps.package.outputs.release_channel == 'preview'" "workflow preview branch"
assert_contains "$workflow" "steps.package.outputs.release_channel == 'stable'" "workflow stable branch"
assert_count "$workflow" "--prerelease" 1 "workflow preview-only prerelease flag"
assert_count "$workflow" "--latest=false" 1 "workflow preview latest-release guard"
assert_contains "$workflow" "unsigned (not Developer ID-signed), ad-hoc-signed, non-notarized preview build" "workflow preview warning"
assert_contains "$workflow" "unsigned (not Developer ID-signed), ad-hoc-signed, non-notarized stable build" "workflow stable warning"
preview_publish_step="$(workflow_step "Publish GitHub preview release")"
stable_publish_step="$(workflow_step "Publish GitHub stable release")"
[[ "$preview_publish_step" == *"--prerelease"* ]] \
    || fail "preview publishing step must mark releases as prereleases"
pass
[[ "$stable_publish_step" != *"--prerelease"* ]] \
    || fail "stable publishing step must not mark releases as prereleases"
pass
[[ "$stable_publish_step" == *"--latest"* && "$stable_publish_step" != *"--latest=false"* ]] \
    || fail "stable publishing step must explicitly mark the release as latest"
pass
assert_contains "$ci_workflow" "permissions:" "CI explicit permissions"
assert_contains "$ci_workflow" "contents: read" "CI read-only contents permission"
assert_contains "$ci_workflow" "runs-on: macos-15" "CI supported runner"
assert_contains "$ci_workflow" 'uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' "CI immutable checkout action"
assert_contains "$ci_workflow" "/bin/bash -n Scripts/*.sh Scripts/lib/*.sh" "CI shell syntax gate"
assert_contains "$ci_workflow" "./Scripts/test-sop.sh" "CI SOP safety gate"
assert_contains "$ci_workflow" "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" "CI unit warning gate"
assert_contains "$ci_workflow" "./Scripts/package-github-release.sh --verify-build-only" "CI Release product gate"
assert_contains "$ci_workflow" '.build/github-release-derived' "CI Release cleanup assertion"
assert_contains "$ci_workflow" '[[ ! -s "$GITHUB_OUTPUT" ]]' "CI no-output assertion"
assert_contains "$package_script" '"SWIFT_TREAT_WARNINGS_AS_ERRORS=YES"' "Release warning gate"
assert_count "$handoff_platform" "await withCheckedContinuation" 1 \
    "workspace-open continuation bridge ownership"
assert_count "$handoff_platform" "await awaitWorkspaceOpen(" 2 \
    "handoff workspace-open bridge adoption"
assert_count "$handoff_platform" "completionHandler: completion" 2 \
    "handoff sendable completion adoption"
assert_count "$launcher_runtime" "withCheckedContinuation" 0 \
    "launcher runtime direct continuation ban"
assert_count "$launcher_runtime" "await awaitWorkspaceOpen(" 1 \
    "settings workspace-open bridge adoption"
assert_count "$launcher_runtime" "completionHandler: completion" 1 \
    "settings sendable completion adoption"

echo "test-github-release: $test_count contract checks passed"
