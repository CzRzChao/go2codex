#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
project_dir="$(cd "$script_dir/.." && /bin/pwd -P)"

source "$script_dir/lib/safety.sh"

usage() {
    echo "Usage: $0 <vX.Y.Z-preview.N|vX.Y.Z>" >&2
    echo "       $0 --validate-only <vX.Y.Z-preview.N|vX.Y.Z>" >&2
    echo "       $0 --verify-build-only" >&2
    exit 64
}

release_die() {
    echo "package-github-release: $*" >&2
    exit 1
}

release_tag=""
release_version=""
release_channel=""
marketing_version=""
build_version=""
archive_name=""
checksum_name=""

load_project_versions() {
    marketing_version="$(xcconfig_value "$project_dir/Config/Base.xcconfig" MARKETING_VERSION)"
    build_version="$(xcconfig_value "$project_dir/Config/Base.xcconfig" CURRENT_PROJECT_VERSION)"

    [[ "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || release_die "MARKETING_VERSION must use numeric major.minor.patch form"
    assert_positive_integer "$build_version" "GitHub release build number"
}

validate_release_contract() {
    local requested_tag="$1"
    local preview_number
    local tag_marketing_version

    load_project_versions
    if [[ "$requested_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-preview\.([1-9][0-9]*)$ ]]; then
        tag_marketing_version="${BASH_REMATCH[1]}"
        preview_number="${BASH_REMATCH[2]}"
        [[ "$preview_number" == "$build_version" ]] \
            || release_die "tag preview number $preview_number does not match CURRENT_PROJECT_VERSION $build_version"
        release_channel="preview"
    elif [[ "$requested_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        tag_marketing_version="${BASH_REMATCH[1]}"
        release_channel="stable"
    else
        release_die "tag must match vX.Y.Z or vX.Y.Z-preview.N, with a positive preview number"
    fi

    [[ "$tag_marketing_version" == "$marketing_version" ]] \
        || release_die "tag version $tag_marketing_version does not match MARKETING_VERSION $marketing_version"

    release_tag="$requested_tag"
    release_version="${requested_tag#v}"
    archive_name="Go2Codex-${release_version}-macos-arm64.zip"
    checksum_name="${archive_name}.sha256"
}

print_release_contract() {
    /usr/bin/printf \
        'release_tag=%s\nrelease_version=%s\nrelease_channel=%s\narchive_path=dist/%s\nchecksum_path=dist/%s\n' \
        "$release_tag" \
        "$release_version" \
        "$release_channel" \
        "$archive_name" \
        "$checksum_name"
}

validate_only=0
verify_build_only=0
case "$#" in
    1)
        if [[ "$1" == "--verify-build-only" ]]; then
            verify_build_only=1
            load_project_versions
        else
            [[ "$1" != --* ]] || usage
            validate_release_contract "$1"
        fi
        ;;
    2)
        [[ "$1" == "--validate-only" ]] || usage
        validate_only=1
        validate_release_contract "$2"
        ;;
    *) usage ;;
esac

if [[ "$validate_only" == "1" ]]; then
    print_release_contract
    exit 0
fi

require_command git
require_command xcodebuild
if [[ "$verify_build_only" != "1" ]]; then
    require_command ditto
    require_command unzip
    require_command shasum
fi

require_clean_git "$project_dir"
if [[ "$verify_build_only" != "1" ]]; then
    head_commit="$(git_head "$project_dir")"
    tag_commit="$(/usr/bin/git -C "$project_dir" rev-parse --verify "refs/tags/$release_tag^{commit}" 2>/dev/null)" \
        || release_die "tag does not exist locally: $release_tag"
    [[ "$tag_commit" == "$head_commit" ]] \
        || release_die "tag $release_tag does not point to the current HEAD"
fi

build_root="$project_dir/.build"
derived_data="$build_root/github-release-derived"
package_root="$build_root/github-release-package"
verification_root="$build_root/github-release-verification"
build_log="$build_root/github-release.log"
product_app="$derived_data/Build/Products/Release/Go2Codex.app"
staged_archive="$package_root/$archive_name"
staged_checksum="$package_root/$checksum_name"
extraction_root="$verification_root/extracted"
extracted_app="$extraction_root/Go2Codex.app"
archive_entries="$verification_root/archive-entries.txt"
dist_dir="$project_dir/dist"
published_archive="$dist_dir/$archive_name"
published_checksum="$dist_dir/$checksum_name"

assert_exact_path "$derived_data" "$project_dir/.build/github-release-derived" "GitHub preview DerivedData"
assert_exact_path "$package_root" "$project_dir/.build/github-release-package" "GitHub preview package staging"
assert_exact_path "$verification_root" "$project_dir/.build/github-release-verification" "GitHub preview verification directory"

cleanup_release_work() {
    local status="$1"
    local cleanup_failed=0
    local path

    trap - EXIT
    trap '' INT TERM
    set +e

    if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
        cleanup_build_registrations "$derived_data" Release || cleanup_failed=1
        cleanup_all_project_build_registrations "$project_dir" || cleanup_failed=1
        assert_no_project_build_registration "$project_dir" || cleanup_failed=1
    fi

    for path in "$derived_data" "$package_root" "$verification_root"; do
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ -d "$path" && ! -L "$path" ]]; then
                /bin/rm -rf -- "$path" || cleanup_failed=1
            else
                cleanup_failed=1
            fi
        fi
    done

    if ! (prepare_regular_output_path "$build_log" "GitHub preview build log"); then
        cleanup_failed=1
    fi

    release_operation_lock || cleanup_failed=1
    if [[ "$cleanup_failed" != "0" && "$status" == "0" ]]; then
        status=1
    fi
    exit "$status"
}

trap 'cleanup_release_work "$?"' EXIT
trap 'cleanup_release_work 130' INT
trap 'cleanup_release_work 143' TERM

ensure_fixed_project_directory "$build_root" "$project_dir/.build" "project build directory"
acquire_operation_lock "$project_dir" product

for path in "$derived_data" "$package_root" "$verification_root"; do
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] \
            || release_die "unsafe existing release work path: $path"
        /bin/rm -rf -- "$path"
    fi
    /bin/mkdir "$path"
done
/bin/mkdir "$extraction_root"

prepare_regular_output_path "$build_log" "GitHub preview build log"
"$script_dir/verify-iterm-handoff.sh"

if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    cleanup_build_registrations "$derived_data" Release
    cleanup_all_project_build_registrations "$project_dir"
    assert_no_project_build_registration "$project_dir"
fi

/usr/bin/xcodebuild clean build \
    -project "$project_dir/Go2Codex.xcodeproj" \
    -scheme Go2Codex \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    "CODE_SIGN_STYLE=Manual" \
    "CODE_SIGN_IDENTITY=-" \
    "DEVELOPMENT_TEAM=" \
    "ARCHS=arm64" \
    "ONLY_ACTIVE_ARCH=NO" \
    "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" \
    | /usr/bin/tee "$build_log"

[[ -d "$product_app" && ! -L "$product_app" ]] \
    || release_die "Release product is missing: $product_app"
"$script_dir/verify-app.sh" \
    "$product_app" \
    Release \
    --signing adhoc \
    --marketing-version "$marketing_version" \
    --build-version "$build_version"

if [[ "$verify_build_only" == "1" ]]; then
    echo "package-github-release: Release product build and verification passed"
    exit 0
fi

/usr/bin/ditto -c -k --keepParent "$product_app" "$staged_archive"
/usr/bin/unzip -tq "$staged_archive" >/dev/null \
    || release_die "release archive failed its ZIP integrity check"
/usr/bin/unzip -Z1 "$staged_archive" >"$archive_entries" \
    || release_die "release archive entries could not be listed"
[[ -s "$archive_entries" ]] || release_die "release archive is empty"
while IFS= read -r entry; do
    case "$entry" in
        Go2Codex.app|Go2Codex.app/*) ;;
        *) release_die "release archive contains an unexpected top-level entry: $entry" ;;
    esac
done <"$archive_entries"

/usr/bin/ditto -x -k "$staged_archive" "$extraction_root"
top_level_count="$(/usr/bin/find "$extraction_root" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$top_level_count" == "1" && -d "$extracted_app" && ! -L "$extracted_app" ]] \
    || release_die "release archive must contain exactly one top-level Go2Codex.app"
"$script_dir/verify-app.sh" \
    "$extracted_app" \
    Release \
    --signing adhoc \
    --marketing-version "$marketing_version" \
    --build-version "$build_version" \
    --compare "$product_app"

(
    cd "$package_root"
    /usr/bin/shasum -a 256 "$archive_name" >"$checksum_name"
    /usr/bin/shasum -a 256 -c "$checksum_name" >/dev/null
)

ensure_fixed_project_directory "$dist_dir" "$project_dir/dist" "GitHub preview distribution directory"
prepare_regular_output_path "$published_archive" "GitHub preview archive"
prepare_regular_output_path "$published_checksum" "GitHub preview checksum"
/bin/mv "$staged_archive" "$published_archive"
/bin/mv "$staged_checksum" "$published_checksum"

if [[ "${GITHUB_ACTIONS:-false}" == "true" && -n "${GITHUB_OUTPUT:-}" ]]; then
    /usr/bin/printf \
        'release_tag=%s\nrelease_version=%s\nrelease_channel=%s\narchive_path=dist/%s\nchecksum_path=dist/%s\n' \
        "$release_tag" \
        "$release_version" \
        "$release_channel" \
        "$archive_name" \
        "$checksum_name" \
        >>"$GITHUB_OUTPUT"
fi

echo "package-github-release: verified unsigned $release_channel archive created"
echo "$published_archive"
echo "$published_checksum"
