# Releasing Go2Codex

This is a maintainer-only guide. Run every command from the repository root. For local development and validation, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Release channels

The repository supports two public release channels:

- Stable tag: `vX.Y.Z`, where `X.Y.Z` equals `MARKETING_VERSION`.
- Preview tag: `vX.Y.Z-preview.N`, where `X.Y.Z` equals `MARKETING_VERSION` and `N` equals the positive, no-leading-zero `CURRENT_PROJECT_VERSION`.

Both channels publish ad-hoc-signed, non-notarized arm64 builds. “Stable” describes the GitHub Release channel only.

## Version metadata

`Config/PublishedRelease.xcconfig` records the last successfully published stable version shown in the two READMEs. It is intentionally independent of the version currently being built.

For every new build, increment `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig`. Change `MARKETING_VERSION` only when the target product version changes. A preview must use its current build number as `N`; preparing or publishing a preview must not change `PUBLISHED_STABLE_VERSION`.

The stable release recorded in `Config/PublishedRelease.xcconfig` is already published, and its protected tag must not be recreated.

## Create and push a release tag

Start from a clean checkout and choose either `stable_tag` or `preview_tag` below. The preflight refuses a dirty tree, a local commit that is not exactly `origin/main`, or a tag that already exists locally or remotely:

```sh
set -euo pipefail

test -z "$(git status --porcelain)"
git switch main
git fetch --no-tags origin "refs/heads/main:refs/remotes/origin/main"
git merge --ff-only origin/main
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"

release_version="$(awk -F= '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' Config/Base.xcconfig)"
build_version="$(awk -F= '/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' Config/Base.xcconfig)"
stable_tag="v${release_version}"
preview_tag="v${release_version}-preview.${build_version}"
release_tag="" # Set to "$stable_tag" or "$preview_tag".

case "$release_tag" in
    "$stable_tag"|"$preview_tag") ;;
    *) echo "Choose a stable or preview release tag." >&2; exit 64 ;;
esac
test -z "$(git tag --list "$release_tag")"
remote_tag_refs="$(git ls-remote --tags origin "refs/tags/${release_tag}")"
test -z "$remote_tag_refs"
Scripts/test-github-release.sh
Scripts/package-github-release.sh --validate-only "$release_tag"
git tag -a "$release_tag" -m "Go2Codex ${release_tag#v}"
git push origin "refs/tags/${release_tag}"
```

Pushing a release tag is the publication action. Never push one merely to test the workflow. Keep stable and preview tag-protection rules active, and never move or delete a published release tag.

## Verify the published release

GitHub Actions builds and verifies the app, checks the ZIP round trip and SHA-256, then publishes the matching stable release or prerelease.

After publication:

1. Download the ZIP and checksum from the GitHub Release.
2. Verify the downloaded checksum.
3. Confirm the Gatekeeper instructions against the downloaded app.
4. Manually test the supported Finder, target, terminal, and session-placement matrix.

Keep `PUBLISHED_STABLE_VERSION` pointing to the previous successful stable release throughout preview work and the stable publication itself. Only after a new stable workflow succeeds and its downloaded assets pass verification should a follow-up documentation pull request update:

- `Config/PublishedRelease.xcconfig`
- Stable links in both READMEs
- Stable asset names in both READMEs
- Any release-specific user-facing prose

`Scripts/test-github-release.sh` keeps the machine-checkable values synchronized.
