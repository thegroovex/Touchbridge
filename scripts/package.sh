#!/bin/bash
# Baut TouchBridge.app (Menüleisten-App + Kommandozeilen-Tool, universal arm64 + x86_64) und verpackt sie als DMG.
# Signatur: mit dem selbstsignierten Zertifikat „TouchBridge Self-Signed (groovex)“, wenn TB_SIGN_IDENTITY (SHA-1 des
# Zertifikats) gesetzt ist (CI: scripts/ci-keychain.sh) – mit expliziter Designated Requirement
#   identifier "com.groovex.touchbridge" and certificate leaf = H"<sha1>"
# Damit bleibt die DR über Builds gleich und macOS behält Eingabeüberwachung/Bedienungshilfen über Updates.
# Ohne TB_SIGN_IDENTITY (z. B. Pull Requests aus Forks, lokale Builds): ad-hoc (DR = cdhash, ändert sich je Build).
# Aufruf: scripts/package.sh <version>   ->  dist/TouchBridge-<version>.dmg + dist/SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."
# Version: argument (CI: release tag without "v"), otherwise the VERSION file (current development version)
ver="${1:-$(cat VERSION 2>/dev/null || echo dev)}"
swift build -c release --arch arm64 --arch x86_64
# last line only: newer SwiftPM (Xcode 27, universal/XCBuild) may print a warning before the path
bindir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path | tail -n 1)"
echo "bin path: $bindir"
for b in TouchBridge TouchBridgeApp; do
  test -x "$bindir/$b"
  archs="$(lipo -archs "$bindir/$b")"; case " $archs " in *" arm64 "*) ;; *) echo "missing arm64: $archs"; exit 1;; esac; case " $archs " in *" x86_64 "*) ;; *) echo "missing x86_64: $archs"; exit 1;; esac
done

rm -rf dist && mkdir -p dist/stage
app="dist/stage/TouchBridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bindir/TouchBridgeApp" "$app/Contents/MacOS/TouchBridgeApp"
cp "$bindir/TouchBridge" "$app/Contents/MacOS/touchbridge"
# SwiftPM's universal build (XCBuild) writes the deployment target into BOTH fields of LC_BUILD_VERSION
# (minos 12.0, sdk 12.0) although it compiles against the selected SDK. AppKit's linked-on-or-after checks read
# that sdk field (dyld program SDK version), so macOS 27 would treat TouchBridge as a macOS 12 app and give it
# only mouse emulation instead of direct touches (TN3212). Set the sdk field to the SDK actually used; minos stays.
sdkv="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [ -n "$sdkv" ]; then
  for f in "$app/Contents/MacOS/TouchBridgeApp" "$app/Contents/MacOS/touchbridge"; do
    bv="$(otool -arch arm64 -l "$f" | grep -A5 LC_BUILD_VERSION)"
    minos="$(echo "$bv" | awk '/ minos /{print $2; exit}')"; cur="$(echo "$bv" | awk '/ sdk /{print $2; exit}')"
    if [ -n "$minos" ] && [ "$cur" != "$sdkv" ]; then
      vtool -set-build-version macos "$minos" "$sdkv" -replace -output "$f.tmp" "$f"
      mv "$f.tmp" "$f"
      echo "LC_BUILD_VERSION of $(basename "$f"): sdk $cur -> $sdkv (minos $minos)"
    fi
  done
fi
build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
num="$(echo "$ver" | grep -Eo '^[0-9]+(\.[0-9]+)*' || echo 0.0.0)"
sed -e "s/__VERSION__/${num:-0.0.0}/" -e "s/__BUILD__/$build/" Resources/Info.plist > "$app/Contents/Info.plist"
# vollständige Version (inkl. -preview…) für den In-App-Updater
plutil -insert TouchBridgeVersion -string "$ver" "$app/Contents/Info.plist"
# Build SDK / Xcode like Xcode-built bundles (DTSDKName etc.) – shown in the Touch Test report. macOS 27 AppKit
# delivers direct touches to gesture recognizers only in apps linked against the macOS 27 SDK (TN3212).
sdkver="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [ -n "$sdkver" ]; then
  plutil -insert DTSDKName -string "macosx$sdkver" "$app/Contents/Info.plist"
  plutil -insert DTPlatformVersion -string "$sdkver" "$app/Contents/Info.plist"
  sdkbuild="$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || true)"
  [ -n "$sdkbuild" ] && plutil -insert DTSDKBuild -string "$sdkbuild" "$app/Contents/Info.plist"
fi
if xv="$(xcodebuild -version 2>/dev/null)"; then
  xver="$(echo "$xv" | awk '/^Xcode/{print $2}')"; xbuild="$(echo "$xv" | awk '/^Build version/{print $3}')"
  IFS=. read -r xa xb xc <<< "$xver"
  plutil -insert DTXcode -string "$(printf '%02d%d%d' "${xa:-0}" "${xb:-0}" "${xc:-0}")" "$app/Contents/Info.plist"
  [ -n "$xbuild" ] && plutil -insert DTXcodeBuild -string "$xbuild" "$app/Contents/Info.plist"
fi
plutil -insert BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$app/Contents/Info.plist"
echo "== build SDK: macosx${sdkver:-?}, Xcode ${xver:-?} (${xbuild:-?}); binary:"
vtool -show-build "$app/Contents/MacOS/TouchBridgeApp" 2>/dev/null | grep -E 'architecture|minos|sdk' || otool -l "$app/Contents/MacOS/TouchBridgeApp" | grep -A4 LC_BUILD_VERSION | grep -E 'minos|sdk'
plutil -lint "$app/Contents/Info.plist"
# App-Icon (scripts/icon/make_icon.py) + Menüleisten-Glyph (Template, 18 pt @1x/@2x)
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$app/Contents/Resources/"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" = AppIcon
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
3. Gerätesteuerung und Datenzugriff (älteres macOS: Bedienungshilfen) und Eingabeüberwachung für TouchBridge erlauben.
   Nach einem Update ggf. einmalig im Terminal:
     tccutil reset ListenEvent com.groovex.touchbridge
     tccutil reset Accessibility com.groovex.touchbridge
   dann TouchBridge starten und erlauben (oder Menü › Berechtigungen ›
   „Berechtigungen zurücksetzen …“).
4. Das TouchBridge-Symbol (Bildschirm mit drei Punkten) in der Menüleiste steuert Touch und Bild.

Mehr: https://github.com/thegroovex/Touchbridge
TXT

# DMG mit Volume-Icon (.VolumeIcon.icns + Custom-Icon-Flag am Volume); ohne SetFile ohne Volume-Icon
cp Resources/AppIcon.icns dist/stage/.VolumeIcon.icns
hdiutil create -volname "TouchBridge $ver" -srcfolder dist/stage -ov -format UDRW -fs HFS+ dist/rw.dmg
mnt="$(mktemp -d)"
hdiutil attach -nobrowse -noautoopen -readwrite -mountpoint "$mnt" dist/rw.dmg >/dev/null
if command -v SetFile >/dev/null 2>&1 || xcrun -f SetFile >/dev/null 2>&1; then
  sf="$(command -v SetFile || xcrun -f SetFile)"
  "$sf" -c icnC "$mnt/.VolumeIcon.icns" || true
  "$sf" -a C "$mnt" && echo "Volume-Icon gesetzt"
else
  echo "Hinweis: SetFile fehlt – DMG ohne Volume-Icon"
fi
sync
hdiutil detach "$mnt" >/dev/null || hdiutil detach -force "$mnt" >/dev/null
hdiutil convert dist/rw.dmg -format UDZO -o "dist/TouchBridge-$ver.dmg" -ov
rm -f dist/rw.dmg
rm -rf dist/stage
(cd dist && shasum -a 256 "TouchBridge-$ver.dmg" > SHA256SUMS.txt)
ls -la dist
