# Use scoped Apple Events for automation

Apple Event sending code will exist only in the Toolbar Launcher, where it reads the frontmost Finder window and creates a CLI session in the selected Terminal Host. Desktop handoffs use official URL schemes instead; neither application entry point will request Accessibility, Full Disk Access, screen recording, or notification privileges, accepting scoped Finder and terminal consent prompts in exchange for a smaller permission surface.

For Apple Events sent by the nested Launcher, macOS evaluates TCC against the outer Go2Codex application as the responsible identity. The outer Settings App and nested Launcher therefore both declare the Apple Events entitlement and localized `NSAppleEventsUsageDescription`, even though an ordinary Settings launch sends no Apple Events. When consent is denied, Go2Codex will explain which Finder or terminal permission is required and offer to open macOS Privacy & Security settings. It will neither loop permission requests nor automate around the user's decision.

The Personal build is ad-hoc signed, so consent continuity across rebuilds is not guaranteed. A stable Developer ID Application identity is introduced only for Public Release.

## Considered Options

- Accessibility or global input monitoring could imitate UI actions but would require broader, less appropriate privileges.
- Apple Events expose the specific Finder and terminal operations the launcher needs and are controlled by macOS Automation consent.
