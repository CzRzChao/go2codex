#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_root="${1:-$script_dir/.build}"

if [[ -e "$output_root" ]]; then
    echo "Output path must not already exist: $output_root" >&2
    exit 1
fi

sdk_path="${GO2CODEX_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc_path="$(xcrun --find swiftc)"
swift_flags=()

if [[ -n "${GO2CODEX_SWIFTC_VFS_OVERLAY:-}" ]]; then
    swift_flags+=("-vfsoverlay" "$GO2CODEX_SWIFTC_VFS_OVERLAY")
fi

outer_app="$output_root/Go2Codex Debug.app"
launcher_app="$outer_app/Contents/Applications/Go2CodexToolbarLauncherDebug.app"
tool_dir="$output_root/.tools"
iconset_dir="$tool_dir/Go2Codex.iconset"

mkdir -p \
    "$outer_app/Contents/MacOS" \
    "$outer_app/Contents/Resources" \
    "$launcher_app/Contents/MacOS" \
    "$launcher_app/Contents/Resources" \
    "$tool_dir"

cp "$script_dir/Resources/Settings-Info.plist" "$outer_app/Contents/Info.plist"
cp "$script_dir/Resources/Launcher-Info.plist" "$launcher_app/Contents/Info.plist"

"$swiftc_path" "${swift_flags[@]}" \
    -sdk "$sdk_path" \
    -target arm64-apple-macosx14.0 \
    "$script_dir/Sources/SettingsProbe.swift" \
    -o "$outer_app/Contents/MacOS/Go2CodexSettingsDebug"

"$swiftc_path" "${swift_flags[@]}" \
    -sdk "$sdk_path" \
    -target arm64-apple-macosx14.0 \
    "$script_dir/Sources/LauncherProbe.swift" \
    -o "$launcher_app/Contents/MacOS/Go2CodexToolbarLauncherDebug"

"$swiftc_path" "${swift_flags[@]}" \
    -sdk "$sdk_path" \
    -target arm64-apple-macosx14.0 \
    "$script_dir/Sources/IconGenerator.swift" \
    -o "$tool_dir/icon-generator"

"$tool_dir/icon-generator" "$iconset_dir"
xcrun iconutil -c icns "$iconset_dir" -o "$tool_dir/Go2Codex.icns"
cp "$tool_dir/Go2Codex.icns" "$outer_app/Contents/Resources/Go2Codex.icns"
cp "$tool_dir/Go2Codex.icns" "$launcher_app/Contents/Resources/Go2Codex.icns"

codesign --force --sign - --timestamp=none "$launcher_app"
codesign --force --sign - --timestamp=none "$outer_app"
codesign --verify --deep --strict "$outer_app"

echo "$outer_app"
