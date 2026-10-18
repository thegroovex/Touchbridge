#!/bin/bash
# Installiert TouchBridge nach /usr/local/bin (aus dem entpackten Release-Ordner starten).
set -euo pipefail
cd "$(dirname "$0")"
sudo mkdir -p /usr/local/bin
sudo cp touchbridge /usr/local/bin/touchbridge
sudo chmod 755 /usr/local/bin/touchbridge
sudo xattr -dr com.apple.quarantine /usr/local/bin/touchbridge 2>/dev/null || true
echo "Installiert: /usr/local/bin/touchbridge"
echo "Nächster Schritt:  touchbridge --list-displays   dann   touchbridge --dump"
