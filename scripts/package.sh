#!/bin/bash
# Baut TouchBridge.app (Menüleisten-App + Kommandozeilen-Tool, universal arm64 + x86_64) und verpackt sie als DMG.
# Signatur: mit dem selbstsignierten Zertifikat „TouchBridge Self-Signed (groovex)“, wenn TB_SIGN_IDENTITY (SHA-1 des
# Zertifikats) gesetzt ist (CI: scripts/ci-keychain.sh) – mit expliziter Designated Requirement
#   identifier "com.groovex.touchbridge" and certificate leaf = H"<sha1>"
# Damit bleibt die DR über Builds gleich und macOS behält Eingabeüberwachung/Bedienungshilfen über Updates.
# Ohne TB_SIGN_IDENTITY (z. B. Pull Requests aus Forks, lokale Builds): ad-hoc (DR = cdhash, ändert sich je Build).
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
# vollständige Version (inkl. -preview…) für den In-App-Updater
plutil -insert TouchBridgeVersion -string "$ver" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
printf 'APPL????' > "$app/Contents/PkgInfo"

# Innen nach außen signieren
sign() { # <identifier> <pfad>
  if [ -n "${TB_SIGN_IDENTITY:-}" ]; then
    leaf="$(echo "$TB_SIGN_IDENTITY" | tr 'A-F' 'a-f')"
    codesign --force --timestamp=none --sign "$TB_SIGN_IDENTITY" ${TB_SIGN_KEYCHAIN:+--keychain "$TB_SIGN_KEYCHAIN"} \
      --identifier "$1" -r="designated => identifier \"$1\" and certificate leaf = H\"$leaf\"" "$2"
  else
    codesign --force --sign - --identifier "$1" "$2"
  fi
}
sign com.groovex.touchbridge.cli "$app/Contents/MacOS/touchbridge"
sign com.groovex.touchbridge "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "== codesign -dr- (Designated Requirement)"
codesign -d -r- "$app" 2>&1
codesign -d -r- "$app/Contents/MacOS/touchbridge" 2>&1
codesign -dv --verbose=2 "$app" 2>&1 | grep -E '^(Identifier|Authority|Signature|CDHash|TeamIdentifier)=' || true
if [ -n "${TB_SIGN_IDENTITY:-}" ]; then
  leaf="$(echo "$TB_SIGN_IDENTITY" | tr 'A-F' 'a-f')"
  codesign -d -r- "$app" 2>&1 | grep -q "identifier \"com.groovex.touchbridge\" and certificate leaf = H\"$leaf\"" \
    || { echo "::error::Designated Requirement der App enthält das Leaf-Zertifikat nicht"; exit 1; }
  codesign -d -r- "$app/Contents/MacOS/touchbridge" 2>&1 | grep -q "identifier \"com.groovex.touchbridge.cli\" and certificate leaf = H\"$leaf\"" \
    || { echo "::error::Designated Requirement des CLI enthält das Leaf-Zertifikat nicht"; exit 1; }
  codesign --verify --strict -R="certificate leaf = H\"$leaf\"" "$app"
  echo "Signiert mit TouchBridge Self-Signed (groovex), Leaf-SHA1 $TB_SIGN_IDENTITY"
else
  echo "Hinweis: ad-hoc signiert (kein TB_SIGN_IDENTITY) – TCC-Rechte gelten nur für diesen Build"
fi

ln -s /Applications "dist/stage/Programme"
cat > "dist/stage/Zuerst lesen.txt" <<TXT
TouchBridge $ver

1. TouchBridge in „Programme“ ziehen.
2. Beim ersten Öffnen: Rechtsklick auf TouchBridge › Öffnen
   (oder Systemeinstellungen › Datenschutz & Sicherheit › „Trotzdem öffnen“).
3. Bedienungshilfen und Eingabeüberwachung für TouchBridge erlauben.
   Kommst du von 0.3.0 oder älter: TouchBridge vorher in beiden Listen
   (Systemeinstellungen › Datenschutz & Sicherheit) mit „–“ entfernen und
   neu erlauben. Ab 0.3.1 bleiben die Rechte über Updates erhalten.
4. Das Hand-Symbol in der Menüleiste steuert Touch und Bild.

Mehr: https://github.com/thegroovex/Touchbridge
TXT

hdiutil create -volname "TouchBridge $ver" -srcfolder dist/stage -ov -format UDZO -fs HFS+ "dist/TouchBridge-$ver.dmg"
rm -rf dist/stage
(cd dist && shasum -a 256 "TouchBridge-$ver.dmg" > SHA256SUMS.txt)
ls -la dist
