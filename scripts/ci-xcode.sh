#!/bin/bash
# CI: select the newest installed Xcode (by CFBundleShortVersionString, e.g. Xcode_27*.app on the xcode-27 image)
# via DEVELOPER_DIR so the app links against the newest macOS SDK (macOS 27: AppKit only delivers direct touches
# to apps built with the 27 SDK – TN3212). Deployment target stays macOS 12 (Package.swift / LSMinimumSystemVersion).
# Usage: scripts/ci-xcode.sh [min-major]   (fails if the newest Xcode is older than min-major)
set -euo pipefail
min="${1:-0}"
best=""; bestver="0"
for x in /Applications/Xcode*.app; do
  [ -d "$x/Contents/Developer" ] || continue
  v="$(defaults read "$x/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0)"
  echo "found $x ($v)"
  if [ "$(printf '%s\n%s\n' "$bestver" "$v" | sort -V | tail -1)" = "$v" ] && [ "$v" != "$bestver" ]; then best="$x"; bestver="$v"; fi
done
[ -n "$best" ] || { echo "::error::no Xcode found"; exit 1; }
# prefer the real path over version symlinks
best="$(cd "$best" && pwd -P)"
echo "selected $best ($bestver)"
if [ "${bestver%%.*}" -lt "$min" ]; then echo "::error::newest Xcode $bestver is older than $min"; exit 1; fi
dev="$best/Contents/Developer"
[ -n "${GITHUB_ENV:-}" ] && echo "DEVELOPER_DIR=$dev" >> "$GITHUB_ENV"
export DEVELOPER_DIR="$dev"
xcodebuild -version
echo "macOS SDK $(xcrun --sdk macosx --show-sdk-version) ($(xcrun --sdk macosx --show-sdk-build-version)) at $(xcrun --sdk macosx --show-sdk-path)"
swift --version
