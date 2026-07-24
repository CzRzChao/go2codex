#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"
package_script="$script_dir/package-github-release.sh"
workflow="$project_dir/.github/workflows/release.yml"
ci_workflow="$project_dir/.github/workflows/ci.yml"
handoff_platform="$project_dir/Sources/Go2CodexLauncher/HandoffPlatform.swift"
launcher_runtime="$project_dir/Sources/Go2CodexLauncher/LauncherRuntime.swift"
published_release_config="$project_dir/Config/PublishedRelease.xcconfig"
english_readme="$project_dir/README.md"
chinese_readme="$project_dir/README.zh-CN.md"
contributing_guide="$project_dir/CONTRIBUTING.md"
release_guide="$project_dir/docs/RELEASING.md"
english_screenshot="$project_dir/docs/assets/settings-en.png"
chinese_screenshot="$project_dir/docs/assets/settings-zh-CN.png"
showcase_finder_screenshot="$project_dir/docs/assets/showcase-finder-toolbar.png"
showcase_picker_screenshot="$project_dir/docs/assets/showcase-target-picker.png"
showcase_workspace_screenshot="$project_dir/docs/assets/showcase-workspace-open.png"
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
    actual_count="$(
        (/usr/bin/grep -F -o -- "$expected" "$file" || true) \
            | /usr/bin/wc -l \
            | /usr/bin/tr -d '[:space:]'
    )"
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

readme_sections() {
    /usr/bin/sed -n \
        's/^<!-- readme-section: \([a-z0-9-]*\) -->$/\1/p' \
        "$1"
}

stable_readme_assets() {
    /usr/bin/grep -Eo \
        '[[:alnum:]_.-]*Go2Codex-[0-9]+\.[0-9]+\.[0-9]+-macos-arm64\.zip(\.sha256)?[[:alnum:]_.-]*' \
        "$1" \
        | /usr/bin/sort -u
}

stable_release_links() {
    /usr/bin/grep -Eo \
        '\]\(https://github\.com/CzRzChao/go2codex/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+\)' \
        "$1" \
        | /usr/bin/sed 's/^](//; s/)$//' \
        | /usr/bin/sort -u
}

readme_maintainer_lines() {
    /usr/bin/grep -E \
        'MARKETING_VERSION|CURRENT_PROJECT_VERSION|PUBLISHED_STABLE_VERSION|xcode-select|xcodebuild|Scripts/|git[[:space:]]+(tag|push)|release_tag' \
        "$1" \
        || true
}

readme_heading_levels() {
    /usr/bin/awk '
        /^[[:space:]]*```/ {
            in_fence = !in_fence
            next
        }
        !in_fence && /^#{1,6}[[:space:]]/ {
            match($0, /^#+/)
            print RLENGTH
        }
    ' "$1"
}

markdown_shell_blocks() {
    /usr/bin/awk '
        /^[[:space:]]*```sh[[:space:]]*$/ {
            in_shell = 1
            print
            next
        }
        in_shell && /^[[:space:]]*```[[:space:]]*$/ {
            print
            in_shell = 0
            next
        }
        in_shell {
            print
        }
        END {
            if (in_shell) {
                exit 1
            }
        }
    ' "$1"
}

markdown_shell_block_count() {
    /usr/bin/awk '
        /^[[:space:]]*```sh[[:space:]]*$/ {
            count++
        }
        END {
            print count + 0
        }
    ' "$1"
}

markdown_shell_code() {
    local target_block="$2"
    /usr/bin/awk -v target_block="$target_block" '
        /^[[:space:]]*```sh[[:space:]]*$/ {
            block++
            in_shell = 1
            next
        }
        in_shell && /^[[:space:]]*```[[:space:]]*$/ {
            in_shell = 0
            next
        }
        in_shell && block == target_block {
            print
        }
        END {
            if (in_shell) {
                exit 1
            }
        }
    ' "$1"
}

validate_markdown_shell_blocks() {
    local file="$1"
    local label="$2"
    local block_count
    local block_index
    local shell_code
    block_count="$(markdown_shell_block_count "$file")"
    [[ "$block_count" -gt 0 ]] \
        || fail "$label shell example code is missing"
    block_index=1
    while [[ "$block_index" -le "$block_count" ]]; do
        shell_code="$(markdown_shell_code "$file" "$block_index")"
        [[ -n "$shell_code" ]] \
            || fail "$label shell example block $block_index is empty"
        /usr/bin/printf '%s\n' "$shell_code" | /bin/bash -n \
            || fail "$label shell example block $block_index contains invalid syntax"
        block_index=$((block_index + 1))
    done
}

png_signature() {
    /usr/bin/od -An -tx1 -N8 "$1" \
        | /usr/bin/tr -d '[:space:]'
}

assert_png_asset() {
    local asset="$1"
    local label="$2"
    [[ -f "$asset" && -s "$asset" && ! -L "$asset" ]] \
        || fail "$label is missing or unsafe"
    pass
    [[ "$(png_signature "$asset")" == "89504e470d0a1a0a" ]] \
        || fail "$label is not a PNG"
    pass
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
[[ -f "$published_release_config" && ! -L "$published_release_config" ]] \
    || fail "published stable release config is missing or unsafe"
pass
published_stable_assignment_count="$(/usr/bin/awk '
    /^[[:space:]]*PUBLISHED_STABLE_VERSION[[:space:]]*=/ {
        count++
    }
    END {
        print count + 0
    }
' "$published_release_config")"
[[ "$published_stable_assignment_count" == "1" ]] \
    || fail "PUBLISHED_STABLE_VERSION must be assigned exactly once"
pass
published_stable_version="$(/usr/bin/awk -F= '
    $1 ~ /^[[:space:]]*PUBLISHED_STABLE_VERSION[[:space:]]*$/ {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
    }
' "$published_release_config")"
[[ "$published_stable_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "PUBLISHED_STABLE_VERSION must use numeric major.minor.patch form"
pass
stable_release_url="https://github.com/CzRzChao/go2codex/releases/tag/v${published_stable_version}"
stable_archive="Go2Codex-${published_stable_version}-macos-arm64.zip"
stable_checksum="${stable_archive}.sha256"
expected_stable_assets="$(/usr/bin/printf '%s\n%s\n' \
    "$stable_archive" \
    "$stable_checksum" \
    | /usr/bin/sort -u)"
expected_readme_sections="$(/usr/bin/printf '%s\n' \
    overview \
    see-it-in-action \
    quick-start \
    requirements \
    download-and-gatekeeper \
    finder-toolbar \
    targets-and-terminal \
    usage \
    update-and-uninstall \
    troubleshooting \
    known-limitations \
    license)"
expected_readme_heading_levels="$(/usr/bin/printf '%s\n' \
    1 \
    2 2 2 2 3 3 \
    2 3 3 \
    2 3 3 \
    2 \
    2 3 3 \
    2 3 3 3 3 3 3 3 3 \
    2 \
    2)"

assert_count "$english_readme" \
    '[简体中文](README.zh-CN.md)' \
    1 \
    "English README language link"
assert_count "$chinese_readme" \
    '[English](README.md)' \
    1 \
    "Chinese README language link"
assert_count "$english_readme" \
    'src="docs/assets/settings-en.png"' \
    1 \
    "English README screenshot link"
assert_count "$chinese_readme" \
    'src="docs/assets/settings-zh-CN.png"' \
    1 \
    "Chinese README screenshot link"
assert_count "$english_readme" \
    'src="docs/assets/showcase-finder-toolbar.png"' \
    1 \
    "English README Finder showcase link"
assert_count "$chinese_readme" \
    'src="docs/assets/showcase-finder-toolbar.png"' \
    1 \
    "Chinese README Finder showcase link"
assert_count "$english_readme" \
    'src="docs/assets/showcase-target-picker.png"' \
    1 \
    "English README target-picker showcase link"
assert_count "$chinese_readme" \
    'src="docs/assets/showcase-target-picker.png"' \
    1 \
    "Chinese README target-picker showcase link"
assert_count "$english_readme" \
    'src="docs/assets/showcase-workspace-open.png"' \
    1 \
    "English README workspace showcase link"
assert_count "$chinese_readme" \
    'src="docs/assets/showcase-workspace-open.png"' \
    1 \
    "Chinese README workspace showcase link"
assert_count "$english_readme" \
    'href="docs/assets/showcase-finder-toolbar.png"' \
    1 \
    "English README Finder showcase full-size link"
assert_count "$chinese_readme" \
    'href="docs/assets/showcase-finder-toolbar.png"' \
    1 \
    "Chinese README Finder showcase full-size link"
assert_count "$english_readme" \
    'href="docs/assets/showcase-target-picker.png"' \
    1 \
    "English README target-picker showcase full-size link"
assert_count "$chinese_readme" \
    'href="docs/assets/showcase-target-picker.png"' \
    1 \
    "Chinese README target-picker showcase full-size link"
assert_count "$english_readme" \
    'href="docs/assets/showcase-workspace-open.png"' \
    1 \
    "English README workspace showcase full-size link"
assert_count "$chinese_readme" \
    'href="docs/assets/showcase-workspace-open.png"' \
    1 \
    "Chinese README workspace showcase full-size link"
assert_count "$english_readme" \
    'PUBLISHED_STABLE_VERSION' \
    0 \
    "English README maintainer metadata"
assert_count "$chinese_readme" \
    'PUBLISHED_STABLE_VERSION' \
    0 \
    "Chinese README maintainer metadata"
assert_count "$english_readme" \
    'Scripts/test.sh' \
    0 \
    "English README maintainer command"
assert_count "$chinese_readme" \
    'Scripts/test.sh' \
    0 \
    "Chinese README maintainer command"
[[ -z "$(readme_maintainer_lines "$english_readme")" ]] \
    || fail "English README contains maintainer-only content"
pass
[[ -z "$(readme_maintainer_lines "$chinese_readme")" ]] \
    || fail "Chinese README contains maintainer-only content"
pass
[[ "$(stable_release_links "$english_readme")" == "$stable_release_url" ]] \
    || fail "English README stable release link set does not match PUBLISHED_STABLE_VERSION"
pass
[[ "$(stable_release_links "$chinese_readme")" == "$stable_release_url" ]] \
    || fail "Chinese README stable release link set does not match PUBLISHED_STABLE_VERSION"
pass
[[ "$(stable_readme_assets "$english_readme")" == "$expected_stable_assets" ]] \
    || fail "English README stable asset set does not match PUBLISHED_STABLE_VERSION"
pass
[[ "$(stable_readme_assets "$chinese_readme")" == "$expected_stable_assets" ]] \
    || fail "Chinese README stable asset set does not match PUBLISHED_STABLE_VERSION"
pass
english_readme_sections="$(readme_sections "$english_readme")"
chinese_readme_sections="$(readme_sections "$chinese_readme")"
[[ "$english_readme_sections" == "$expected_readme_sections" ]] \
    || fail "English README section contract changed"
pass
[[ "$chinese_readme_sections" == "$expected_readme_sections" ]] \
    || fail "Chinese README section contract changed"
pass
[[ "$english_readme_sections" == "$chinese_readme_sections" ]] \
    || fail "English and Chinese README section contracts differ"
pass
english_heading_levels="$(readme_heading_levels "$english_readme")"
chinese_heading_levels="$(readme_heading_levels "$chinese_readme")"
[[ "$english_heading_levels" == "$expected_readme_heading_levels" ]] \
    || fail "English README heading-level contract changed"
pass
[[ "$chinese_heading_levels" == "$expected_readme_heading_levels" ]] \
    || fail "Chinese README heading-level contract changed"
pass
[[ "$english_heading_levels" == "$chinese_heading_levels" ]] \
    || fail "English and Chinese README heading-level contracts differ"
pass
english_shell_blocks="$(markdown_shell_blocks "$english_readme")"
chinese_shell_blocks="$(markdown_shell_blocks "$chinese_readme")"
[[ -n "$english_shell_blocks" ]] \
    || fail "English README shell examples are missing"
pass
[[ "$english_shell_blocks" == "$chinese_shell_blocks" ]] \
    || fail "English and Chinese README shell examples differ"
pass
validate_markdown_shell_blocks "$english_readme" "README"
pass
[[ -f "$contributing_guide" && -s "$contributing_guide" && ! -L "$contributing_guide" ]] \
    || fail "contributor guide is missing or unsafe"
pass
assert_contains "$contributing_guide" \
    '[docs/RELEASING.md](docs/RELEASING.md)' \
    "contributor guide release link"
assert_contains "$contributing_guide" \
    'Scripts/test.sh' \
    "contributor guide test command"
validate_markdown_shell_blocks "$contributing_guide" "Contributor guide"
pass
[[ -f "$release_guide" && -s "$release_guide" && ! -L "$release_guide" ]] \
    || fail "release guide is missing or unsafe"
pass
assert_contains "$release_guide" \
    'release_tag="" # Set to "$stable_tag" or "$preview_tag".' \
    "release guide explicit channel choice"
assert_contains "$release_guide" \
    'remote_tag_refs="$(git ls-remote --tags origin "refs/tags/${release_tag}")"' \
    "release guide remote tag query"
assert_contains "$release_guide" \
    'git push origin "refs/tags/${release_tag}"' \
    "release guide publication command"
assert_contains "$release_guide" \
    'PUBLISHED_STABLE_VERSION' \
    "release guide published stable lifecycle"
validate_markdown_shell_blocks "$release_guide" "Release guide"
pass
assert_png_asset "$english_screenshot" "English README screenshot"
assert_png_asset "$chinese_screenshot" "Chinese README screenshot"
assert_png_asset "$showcase_finder_screenshot" "Finder showcase screenshot"
assert_png_asset "$showcase_picker_screenshot" "Target-picker showcase screenshot"
assert_png_asset "$showcase_workspace_screenshot" "Workspace showcase screenshot"

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
assert_contains "$workflow" "./Scripts/test-github-release.sh" "workflow README contract gate"
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
assert_contains "$ci_workflow" "./Scripts/test-github-release.sh" "CI README contract gate"
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
