#!/bin/bash
# Baut TouchBridge.app (Menüleisten-App + Kommandozeilen-Tool, universal arm64 + x86_64, ad-hoc signiert)
# und verpackt sie als DMG zum Reinziehen in „Programme“.
# Aufruf: scripts/package.sh <version>   ->  dist/TouchBridge-<version>.dmg + dist/SHA256SUMS.txt
set -euo pipefail
ver="${1:-dev}"
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
bindir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
for b in TouchBridge TouchBridgeApp; do
  test -x "$bindir/$b"
  lipo "$bindir/$b" -verify_arch arm64 x86_64
done

rm -rf dist && mkdir -p dist/stage
app="dist/stage/TouchBridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bindir/TouchBridgeApp" "$app/Contents/MacOS/TouchBridgeApp"
cp "$bindir/TouchBridge" "$app/Contents/MacOS/touchbridge"
build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
num="$(echo "$ver" | grep -Eo '^[0-9]+(\.[0-9]+)*' || echo 0.0.0)"
sed -e "s/__VERSION__/${num:-0.0.0}/" -e "s/__BUILD__/$build/" Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
printf 'APPL????' > "$app/Contents/PkgInfo"

# Innen nach außen signieren (ad-hoc; ohne Apple-Developer-ID)
codesign --force --sign - --identifier com.groovex.touchbridge.cli "$app/Contents/MacOS/touchbridge"
codesign --force --sign - --identifier com.groovex.touchbridge "$app"
codesign --verify --deep --strict "$app"

ln -s /Applications "dist/stage/Programme"
cat > "dist/stage/Zuerst lesen.txt" <<TXT
TouchBridge $ver

1. TouchBridge in „Programme“ ziehen.
2. Beim ersten Öffnen: Rechtsklick auf TouchBridge › Öffnen
   (oder Systemeinstellungen › Datenschutz & Sicherheit › „Trotzdem öffnen“).
3. Bedienungshilfen und Eingabeüberwachung für TouchBridge erlauben.
4. Das Hand-Symbol in der Menüleiste steuert Touch und Bild.

Mehr: https://github.com/thegroovex/Touchbridge
TXT

hdiutil create -volname "TouchBridge $ver" -srcfolder dist/stage -ov -format UDZO -fs HFS+ "dist/TouchBridge-$ver.dmg"
rm -rf dist/stage
(cd dist && shasum -a 256 "TouchBridge-$ver.dmg" > SHA256SUMS.txt)
ls -la dist
