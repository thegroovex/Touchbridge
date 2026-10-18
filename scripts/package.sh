#!/bin/bash
# Baut das Release-Paket: universelles Binary (arm64 + x86_64), ad-hoc signiert, mit README, Installer und LaunchAgent.
# Aufruf: scripts/package.sh <version>   (Ausgabe: dist/TouchBridge-<version>-macOS-universal.zip)
set -euo pipefail
ver="${1:-dev}"
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TouchBridge"
test -x "$bin"
lipo "$bin" -verify_arch arm64 x86_64
name="TouchBridge-$ver-macOS-universal"
rm -rf "dist/$name" && mkdir -p "dist/$name"
cp "$bin" "dist/$name/touchbridge"
codesign --force --sign - --identifier com.groovex.touchbridge "dist/$name/touchbridge"
cp README.md com.groovex.touchbridge.plist scripts/install.sh "dist/$name/"
chmod +x "dist/$name/install.sh"
(cd dist && ditto -c -k --keepParent "$name" "$name.zip")
(cd dist && shasum -a 256 "$name.zip" > SHA256SUMS.txt)
ls -la dist
