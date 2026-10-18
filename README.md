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

## Installieren
1. Unter **Releases** `TouchBridge-<version>.dmg` laden (Apple Silicon und Intel, ab macOS 12).
2. DMG öffnen, **TouchBridge** auf „Programme“ ziehen.
3. Erster Start: Rechtsklick auf TouchBridge › **Öffnen** (die App ist nicht von Apple notarisiert),
   alternativ Systemeinstellungen › Datenschutz & Sicherheit › „Trotzdem öffnen“.
4. **Bedienungshilfen** und **Eingabeüberwachung** für TouchBridge erlauben.

Danach sitzt ein Hand-Symbol in der Menüleiste.

## Menüleiste
- **Touch aktiv** an/aus, Status des erkannten Touch-Monitors
- **Bild**: Helligkeit, Kontrast, Lautstärke per DDC/CI (Apple-Silicon-Macs, wenn der Monitor DDC kann),
  dazu Software-Abdunkeln für jeden Bildschirm
- **Touch**: Ziel-Bildschirm, Ausrichtung (0/90/180/270°, spiegeln), Scrollrichtung und -tempo, exklusiver Modus
- **Beim Anmelden starten** (ab macOS 13), Berechtigungen prüfen
- **Diagnose aufzeichnen**: 10 s Touch-Rohdaten, landen in der Zwischenablage und als
  `TouchBridge-Diagnose.txt` auf dem Schreibtisch
- **Kommandozeilen-Tool installieren**: verlinkt `touchbridge` nach `/usr/local/bin`

## Kommandozeile
`touchbridge --list-displays`, `touchbridge --dump`, `touchbridge --rotate 90`,
`touchbridge --brightness 60`, `touchbridge --get volume` – alle Optionen: `touchbridge --help`.

## Selbst bauen
Voraussetzung: Xcode Command Line Tools (`xcode-select --install`).

```bash
swift build -c release
swift test                       # Unit-Tests (Descriptor-Parser, Frames, Gesten)
scripts/package.sh dev           # TouchBridge.app als DMG nach dist/
```

## Aufbau
- `Sources/TouchBridgeCore` – HID-Descriptor-Parser, Frame-Zusammenbau (inkl. Hybrid-Modus), Gesten-Engine, Mapping, DDC-Pakete
- `Sources/TouchBridgeKit` – IOKit-HID-Dienst, Bildschirme, Bildsteuerung (DDC über IOAVService / Gamma), Rechte
- `Sources/TouchBridgeApp` – Menüleisten-App
- `Sources/TouchBridge` – Kommandozeilen-Tool
- `Tests/TouchBridgeCoreTests` – XCTest mit typischen Touchscreen-Descriptoren und Gesten-Szenarien
- `.github/workflows/ci.yml` – CI: universal Build + Tests (Apple Silicon + Intel), Paket als Artefakt, Release-Upload

## Erster Test
1. Monitor per USB-C anschließen (Bild + Touch über dasselbe Kabel), TouchBridge starten.
2. Menü › **Diagnose aufzeichnen** und 10 s den Bildschirm berühren – die Datei hilft beim Anpassen.
3. Landet der Touch gedreht oder gespiegelt: Menü › Touch › Ausrichtung.

Klappt der exklusive Zugriff nicht, bewegt macOS den Cursor zusätzlich selbst; dann im Terminal
`sudo touchbridge` als Gegenprobe starten und mir die Diagnose schicken.
