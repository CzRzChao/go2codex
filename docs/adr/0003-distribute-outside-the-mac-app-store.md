# Distribute outside the Mac App Store through GitHub Releases

Go2Codex uses local builds for the Personal MVP and GitHub Releases as its only public download channel. Before a Developer ID is available, `vX.Y.Z-preview.N` tags may publish an arm64 ZIP as an explicitly ad-hoc-signed, non-notarized GitHub pre-release. Stable `vX.Y.Z` tags remain reserved for a future Developer ID-signed and notarized Public Release.

The Mac App Store requires App Sandbox, whose restrictions and review expectations conflict with the Finder and terminal Apple Events central to Go2Codex. DMG, Homebrew, Sparkle, Intel, Universal, and Mac App Store distribution are not part of the preview channel.

## Consequences

The project does not need to shape its automation around App Store sandbox exceptions, but it owns download integrity, update instructions, signing state, and Gatekeeper documentation. Preview releases must remain visibly marked as pre-releases, publish a SHA-256 checksum, reject stable tags, and document the manual Gatekeeper override. They do not satisfy the stable Public Release gate. A future stable release must add Developer ID signing, notarization, stapling, Gatekeeper assessment, and clean-machine validation without changing the GitHub ZIP distribution channel.
