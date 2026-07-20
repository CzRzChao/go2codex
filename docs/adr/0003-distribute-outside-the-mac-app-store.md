# Distribute outside the Mac App Store

Go2Codex will use local builds for the Personal MVP and GitHub Releases for the Public Release, with Homebrew Cask as a possible additional channel. The Mac App Store requires App Sandbox, whose restrictions and review expectations conflict with the Finder and terminal Apple Events central to Go2Codex; a future public build will instead use Developer ID signing and notarization.

## Consequences

The project does not need to shape its automation around App Store sandbox exceptions, but it must own its download, update, signing, notarization, and Gatekeeper documentation outside the store.
