# TouchBridge – Multitouch für den Anmite A140W05T am Mac

[![CI](https://github.com/thegroovex/Touchbridge/actions/workflows/ci.yml/badge.svg)](https://github.com/thegroovex/Touchbridge/actions/workflows/ci.yml)

macOS kennt keine Touchscreens. Der Monitor meldet sich über USB-C als
Standard-HID-Multitouch-Digitizer (deshalb klappt es unter Android sofort).
TouchBridge liest diese Touch-Daten direkt, übernimmt das Gerät exklusiv und
übersetzt die Finger in macOS-Eingaben.

## Gesten
| Geste | Wirkung |
|---|---|
| 1 Finger tippen | Klick (2× tippen = Doppelklick) |
| 1 Finger ziehen | Ziehen / Markieren / Fenster verschieben |
| 1 Finger halten (~0,65 s) | Rechtsklick |
| 2 Finger tippen | Rechtsklick |
| 2 Finger schieben | Scrollen (vertikal + horizontal, pixelgenau) |
| 2 Finger spreizen/zusammen | Zoom (Cmd + / Cmd −) |
| 3 Finger links/rechts | Space wechseln (Ctrl ←/→) |
| 3 Finger hoch / runter | Mission Control / App-Exposé |

## Installieren (fertige Version)
1. Unter **Releases** `TouchBridge-<version>-macOS-universal.zip` laden (läuft auf Apple Silicon und Intel, ab macOS 12).
2. Entpacken, im Terminal in den Ordner wechseln und `./install.sh` ausführen
   (kopiert nach `/usr/local/bin/touchbridge` und entfernt die Download-Quarantäne).

## Selbst bauen
Voraussetzung: Xcode Command Line Tools (`xcode-select --install`).

```bash
swift build -c release
swift test                       # Unit-Tests (Descriptor-Parser, Frames, Gesten)
scripts/package.sh dev           # universelles Paket nach dist/
```

## Aufbau
- `Sources/TouchBridgeCore` – HID-Descriptor-Parser, Frame-Zusammenbau (inkl. Hybrid-Modus), Gesten-Engine
- `Sources/TouchBridge` – CLI: IOKit-HID, Bildschirm-Mapping, Rechte
- `Tests/TouchBridgeCoreTests` – XCTest mit typischen Touchscreen-Descriptoren und Gesten-Szenarien
- `.github/workflows/ci.yml` – CI: universal Build + Tests (Apple Silicon + Intel), Paket als Artefakt, Release-Upload

## Erster Test
1. Monitor per USB-C anschließen (Bild + Touch über dasselbe Kabel).
2. `touchbridge --list-displays` → Nummer des Anmite merken.
3. `touchbridge --dump --display N` → Bildschirm berühren. Es sollten Zeilen wie
   `2 Finger: #0 raw(…) -> (x,y)` erscheinen.
4. Läuft das: `sudo touchbridge --display N`

Beim ersten Start fragt macOS nach **Bedienungshilfen** und **Eingabeüberwachung**
(für das Terminal). Beides erlauben und neu starten.
`sudo` wird gebraucht, damit TouchBridge das Gerät exklusiv bekommt – sonst bewegt
macOS den Cursor zusätzlich selbst.

## Anpassen
- Touch landet gespiegelt/gedreht: `--flip-x`, `--flip-y`, `--swap-xy` kombinieren.
- Scrollrichtung falsch: `--invert-scroll`; zu langsam/schnell: `--scroll-gain 1.5`.
- Bestimmtes Gerät: `--vid 0x222A --pid 0x0001` (Werte zeigt `--dump`).

## Wenn nichts erkannt wird
`--dump` gibt dann den HID-Descriptor als Hex aus – einfach mir schicken, dann passe ich den Parser an.

## Autostart (optional, experimentell)
Erst wenn der manuelle Start sauber läuft: `com.groovex.touchbridge.plist` nach `~/Library/LaunchAgents/`
kopieren (Display-Nummer anpassen) und `launchctl load ~/Library/LaunchAgents/com.groovex.touchbridge.plist`.
Als LaunchAgent läuft es ohne root – klappt der exklusive Zugriff dann nicht, siehe `/tmp/touchbridge.log`.
