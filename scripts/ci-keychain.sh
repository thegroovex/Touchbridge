#!/bin/bash
# CI: Signier-Identität aus den Secrets TB_SIGN_P12 (base64) + TB_SIGN_P12_PASSWORD in eine temporäre Keychain
# importieren und TB_SIGN_IDENTITY / TB_SIGN_KEYCHAIN für scripts/package.sh setzen.
# Fehlt das Secret (z. B. Pull Requests aus Forks), bleibt alles leer -> package.sh signiert ad-hoc.
set -euo pipefail
if [ -z "${TB_SIGN_P12:-}" ]; then
  echo "Kein TB_SIGN_P12 – Paket wird ad-hoc signiert."
  exit 0
fi
kc="$RUNNER_TEMP/tb-sign.keychain-db"
kcpw="$(uuidgen)"
p12="$RUNNER_TEMP/tb-sign.p12"
security create-keychain -p "$kcpw" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$kcpw" "$kc"
printf '%s' "$TB_SIGN_P12" | base64 --decode > "$p12"
security import "$p12" -k "$kc" -P "$TB_SIGN_P12_PASSWORD" -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security
rm -f "$p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpw" "$kc" > /dev/null
# Keychain in die Suchliste aufnehmen (codesign findet die Identität sonst nicht)
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')
sha1="$(security find-certificate -c "TouchBridge Self-Signed (groovex)" -Z "$kc" | awk '/SHA-1 hash:/ {print $NF}')"
[ -n "$sha1" ] || { echo "::error::Zertifikat nicht in der Keychain gefunden"; exit 1; }
echo "Identitäten in der Keychain (selbstsigniert = nicht vertrauenswürdig, für codesign aber nutzbar):"
security find-identity -p codesigning "$kc" || true
echo "TB_SIGN_IDENTITY=$sha1" >> "$GITHUB_ENV"
echo "TB_SIGN_KEYCHAIN=$kc" >> "$GITHUB_ENV"
echo "Signier-Identität: TouchBridge Self-Signed (groovex), SHA-1 $sha1"
