#!/bin/bash
# Einmalig auf dem eigenen Mac ausführen: erzeugt lokal das selbstsignierte Code-Signing-Zertifikat
# „TouchBridge Self-Signed (groovex)“ (RSA 2048, EKU codeSigning, 10 Jahre), packt es mit Zufallspasswort als .p12
# und speichert beides als GitHub-Actions-Secrets (TB_SIGN_P12 = base64, TB_SIGN_P12_PASSWORD).
# Danach werden alle lokalen Schlüsseldateien gelöscht; der private Schlüssel existiert nur noch als Secret.
# CI (scripts/ci-keychain.sh + package.sh) signiert damit mit fester Designated Requirement
#   identifier "com.groovex.touchbridge" and certificate leaf = H"<sha1>"
# -> macOS behält Eingabeüberwachung/Bedienungshilfen über Updates.
# Aufruf: scripts/setup-signing.sh [owner/repo]     (Standard: thegroovex/Touchbridge)
set -euo pipefail
repo="${1:-thegroovex/Touchbridge}"
cn="TouchBridge Self-Signed (groovex)"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI fehlt. Installieren und anmelden:"
  echo "  brew install gh && gh auth login"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI ist nicht angemeldet. Bitte zuerst:"
  echo "  gh auth login"
  exit 1
fi
if gh secret list -R "$repo" 2>/dev/null | grep -q '^TB_SIGN_P12\b'; then
  read -r -p "TB_SIGN_P12 existiert schon in $repo. Neues Zertifikat erzeugen und ersetzen? (Rechte am Mac müssen dann einmal neu erteilt werden) [j/N] " a
  [ "$a" = j ] || [ "$a" = J ] || { echo "Abgebrochen."; exit 0; }
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
cd "$work"
cat > req.cnf <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $cn
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config req.cnf 2>/dev/null
pw="$(openssl rand -hex 16)"
# macOS „security import“ versteht nur die klassischen PKCS#12-Algorithmen (3DES/RC2, MAC SHA-1)
legacy=""
if openssl version | grep -q '^OpenSSL 3'; then legacy="-legacy"; fi
openssl pkcs12 -export $legacy -inkey key.pem -in cert.pem -name "$cn" -passout "pass:$pw" -out tb.p12
openssl base64 -A -in tb.p12 > tb.p12.b64

sha1="$(openssl x509 -in cert.pem -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
gh secret set TB_SIGN_P12 -R "$repo" < tb.p12.b64
printf '%s' "$pw" | gh secret set TB_SIGN_P12_PASSWORD -R "$repo"
unset pw
rm -f key.pem tb.p12 tb.p12.b64 req.cnf

echo
echo "✅ Secrets TB_SIGN_P12 und TB_SIGN_P12_PASSWORD in $repo gesetzt; lokale Schlüsseldateien gelöscht."
echo "   Zertifikat: $cn"
echo "   Leaf-SHA1:  $sha1"
echo "   Designated Requirement: identifier \"com.groovex.touchbridge\" and certificate leaf = H\"$(echo "$sha1" | tr 'A-F' 'a-f')\""
echo
echo "Nächste Schritte: CI neu laufen lassen (z. B. Actions › CI › Run workflow) bzw. nächstes Release erstellen."
echo "Nach der Installation des ersten so signierten Builds einmalig:"
echo "  tccutil reset ListenEvent com.groovex.touchbridge; tccutil reset Accessibility com.groovex.touchbridge"
echo "dann TouchBridge starten und beide Rechte erlauben – danach bleiben sie über Updates erhalten."
