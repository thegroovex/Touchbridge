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

## MIDI-Modus (MIDI-Controller & MPE)
Statt Maus & Gesten kann der Touch-Monitor als MIDI-Controller arbeiten. Menü › **Modus › MIDI**
(oder `touchbridge --midi`). TouchBridge legt dann den virtuellen MIDI-Port **„TouchBridge“** an,
sendet keine Maus-/Tastatur-Events mehr und übernimmt das Touch-Gerät exklusiv. Auf dem
Touch-Bildschirm liegt ein durchsichtiges Overlay, das Fader, Pads, XY-Feld und Tasten zeigt
(durchklickbar, abschaltbar unter **MIDI-Einstellungen › Layout auf dem Touch-Bildschirm anzeigen**).

**Layouts** (Menü › MIDI-Einstellungen › Layout bzw. `--layout`):
| Layout | Inhalt | MIDI |
|---|---|---|
| `mixer` | 8 Fader oben, 8 Pads unten | Fader CC 20–27, Pads ab Grundnote (Anschlag oben = laut) |
| `keyboard` | 2 Tastenreihen (MPE-Keyboard), obere Reihe eine Oktave höher | Noten ab Grundnote, Skala wählbar |
| `performance` | 4 Fader, XY-Feld, 8 Pads | Fader CC 20–23, XY = CC 16 (X) / CC 17 (Y), Pads ab Grundnote |

- Jeder Finger bleibt an der Zone, in der er aufgesetzt hat (bis 10 Finger gleichzeitig) –
  ein Fader lässt sich also nicht versehentlich in den Nachbarfader „ziehen“.
- Fader: unten 0, oben 127. Pads: Note On beim Aufsetzen, Note Off beim Abheben.
- **MPE** (Standard an, nur für Keyboard-Zonen): Lower Zone, Master = Kanal 1, jede Note auf einem
  eigenen Kanal 2–16. Seitliches Rutschen = Pitch Bend relativ zum Anschlagpunkt (±48 Halbtöne,
  zwischen den Tastenmitten wird auf die Skalentöne interpoliert), Hoch/Runter in der Taste = CC 74
  („Slide“/Timbre), Druck = Channel Pressure – sofern der Monitor Druck oder Kontaktgröße meldet.
  Beim Start werden RPN 6 (MPE-Konfiguration, 15 Member-Kanäle) und RPN 0 (Bend-Bereich) gesendet.
  Mit MPE gehen Fader, Pads und XY auf Kanal 1.
- **Ohne MPE** (`--no-mpe`): alles auf dem gewählten MIDI-Kanal, kein Pitch Bend, Druck als Poly Aftertouch.
- Werte werden nur bei Änderung gesendet, höchstens ~250× pro Sekunde und Kanal.
- Ausrichtung (Menü › Touch › Ausrichtung) gilt auch hier: Das Layout liegt immer richtig herum auf dem Bild.

Kommandozeile: `touchbridge --midi --layout keyboard`, `touchbridge --midi --layout mixer --no-mpe --channel 10`,
weitere Optionen `--base-note 36`, `--scale minor`, `--bend-range 24`.

### Ableton Live
1. TouchBridge im MIDI-Modus starten.
2. Live › Einstellungen › **Link, Tempo & MIDI**: beim Eingang **TouchBridge** „Spur“ (Track) und für
   MIDI-Mapping „Fernsteuerung“ (Remote) einschalten.
3. **Fader/XY**: Cmd+M (MIDI-Map-Modus), Parameter in Live anklicken, Fader auf dem Touch-Monitor bewegen, Cmd+M beenden.
4. **Pads**: MIDI-Spur mit Drum Rack, Eingang „TouchBridge“, Monitor „In“ oder Spur scharf schalten.
   Für Drum Racks die Grundnote auf C1 (36) stellen.
5. **MPE (Live 11 und 12)**: Layout `keyboard`, MPE an. MIDI-Spur mit MPE-fähigem Instrument
   (z. B. Drift, Meld, Wavetable, Sampler – im Gerätemenü „MPE aktivieren“). Eingang „TouchBridge“,
   im Eingangsmenü der Spur **MPE** wählen. Pitch-Bend-Bereich des Instruments auf 48 Halbtöne
   (Standard bei MPE). Live 11/12 zeichnet MPE-Daten pro Note auf und zeigt sie im Clip-Editor („Note Expression“).

### Ohpe
- **Standalone**: Zahnrad › MIDI › Eingang „TouchBridge“ aktivieren.
- **Als Plug-in** (VST3/AU in Live, Logic …): MIDI kommt über die Spur – Spureingang „TouchBridge“ wählen.
- Fader, XY und Pads per **MIDI learn** (Zahnrad › MIDI learn) auf Parameter, Mixer oder Transport legen.
- Zum Spielen der Klangerzeuger MPE ausschalten (Menü bzw. `--no-mpe`) und den MIDI-Kanal wählen,
  auf dem der Part hört – ein MPE-Keyboard verteilt die Noten sonst auf die Kanäle 2–16.

### livelooper
- **Standalone**: in den Audio-/MIDI-Einstellungen „TouchBridge“ als MIDI-Eingang aktivieren;
  **als Plug-in** kommt MIDI über den Spureingang der DAW.
- **MIDI-Learn** einschalten, das Bedienelement (Record/Play/Overdub, Lautstärke, Loop-Länge …) anklicken und
  Pad bzw. Fader auf dem Touch-Monitor berühren.
- Passende Layouts: `mixer` (8 Fader = Spurlautstärken, 8 Pads = Loop-Tasten) oder `performance` (XY-Feld für Effekte),
  jeweils mit `--no-mpe`.

## Berechtigungen
TouchBridge braucht **Eingabeüberwachung** (sonst liefert macOS keine Touch-Reports) und für Maus & Gesten
**Gerätesteuerung und Datenzugriff** (so heißt die Seite ab macOS 27; älteres macOS: **Bedienungshilfen**) –
Events senden, Systemzeiger-Filter. Beide Dialoge kommen nur **einmal** automatisch;
danach zeigt das Menü nur noch einen Hinweis.

- **Stabile Signatur:** Sind die Signier-Secrets gesetzt (siehe unten), signiert die CI mit dem selbstsignierten
  Zertifikat „TouchBridge Self-Signed (groovex)“ und fester Designated Requirement
  `identifier "com.groovex.touchbridge" and certificate leaf = H"<sha1>"` (CLI: `com.groovex.touchbridge.cli`).
  macOS erkennt neue Versionen dadurch als dieselbe App – die Rechte bleiben über Updates erhalten. Der In-App-Updater
  installiert dann nur Bundles mit demselben Leaf-Zertifikat. Ohne Secrets wird ad-hoc signiert (Designated Requirement
  = cdhash, ändert sich mit jedem Build → Rechte nach jedem Update neu erteilen).
- **Nach einem Update auf einen ad-hoc-Build bzw. beim Umstieg auf den ersten signierten Build (einmalig):**
  `tccutil reset ListenEvent com.groovex.touchbridge; tccutil reset Accessibility com.groovex.touchbridge`, dann
  TouchBridge starten und beide Rechte erlauben – oder in Systemeinstellungen › Datenschutz & Sicherheit ›
  **Eingabeüberwachung** / **Gerätesteuerung und Datenzugriff** (Bedienungshilfen) TouchBridge mit „–“ entfernen und neu hinzufügen. Dasselbe macht
  Menü › Berechtigungen › **Berechtigungen zurücksetzen …**.
- **Wirkung statt Schalter:** Der Status richtet sich nach dem tatsächlichen Ergebnis – kommen Reports an, gilt die
  Berechtigung als wirksam; ist sie laut System erteilt, das Öffnen scheitert aber mit `kIOReturnNotPermitted`, meldet das
  Menü „Eintrag veraltet – in Systemeinstellungen entfernen (–) und neu hinzufügen“.

### Signier-Zertifikat einrichten (einmalig, auf dem eigenen Mac)
`scripts/setup-signing.sh` erzeugt lokal das selbstsignierte Zertifikat (RSA 2048, EKU codeSigning, 10 Jahre),
packt es mit Zufallspasswort als .p12 und speichert es per GitHub CLI als Actions-Secrets `TB_SIGN_P12` (base64) und
`TB_SIGN_P12_PASSWORD`; danach löscht es alle lokalen Schlüsseldateien und gibt den Leaf-SHA1 aus. Voraussetzung:
`brew install gh && gh auth login`. Der private Schlüssel verlässt den Mac nur in Richtung GitHub-Secrets.

### Exklusiver Zugriff und Systemzeiger
Der Anmite meldet sich mit **drei HID-Schnittstellen** (Touch-Digitizer, Maus/Pointer, Vendor). Über die Maus-Schnittstelle
bewegt macOS selbst den Zeiger (AppleUserHIDEventDriver → WindowServer). TouchBridge öffnet deshalb **alle** Schnittstellen
des Monitors genau einmal (dedupliziert per IORegistryEntryID) und **exklusiv**; das Menü zeigt den Stand je Schnittstelle,
z. B. „3 Schnittstellen: Touch exklusiv, Maus exklusiv, Vendor exklusiv“, dazu, welche Schnittstelle tatsächlich
Daten liefert („Reports: Touch: 0 Reports, Maus: 120 Reports, Vendor: 0 Reports“) und die Quelle.

### Multitouch oder Single-Touch (Gerät im Mausmodus)
Jede Schnittstelle, deren Report-Descriptor Finger beschreibt, ist Multitouch-Quelle. Eine Schnittstelle mit
**absoluten** X/Y (ohne Relative-Flag) und Button 1 bzw. Tip Switch – z. B. die Maus-Schnittstelle des Anmite
(Report 7: 3 Buttons, X 0…16383, Y 0…9599, Rad) – dient als **Single-Touch-Fallback**: Button 1 = Berührung,
Koordinaten absolut auf den Touch-Bildschirm. Tippen = Klick, Ziehen = Drag, Halten = Rechtsklick; mit
„1-Finger-Ziehen scrollt“ (Terminal: `--one-finger-scroll`) wird aus dem Ziehen Scrollen.

Der Anmite sendet am Mac zunächst nur auf der Maus-Schnittstelle (wie Windows vor dem Input-Mode-Wechsel). Beim Öffnen
versucht TouchBridge automatisch, Multitouch einzuschalten, und prüft nach jedem Versuch während einer Berührung 2 s
lang, ob Multitouch-Reports kommen: (1) GetReport „Contact Count Maximum“, dann SetReport Input Mode 2 `[21 02 00]`
(Reihenfolge wie Linux hid-multitouch), (2) dieselben Daten ohne Report-ID `[02 00]`, (3) Input Mode 3 `[21 03 00]`.
Klappt ein Versuch, läuft der Multitouch-Pfad und die Maus-Schnittstelle wird nur noch exklusiv gehalten und verworfen;
sonst bleibt es bei Single-Touch und das Menü zeigt „Single-Touch (Gerät im Mausmodus)“. Alle Versuche stehen mit
Return-Codes und Feature-Inhalten in der Diagnose.

**Exklusiv nur Touch-Schnittstelle** (Menü, Terminal `--seize-touch-only`) ist eine Testoption: nur der Digitizer wird
exklusiv übernommen, Maus/Vendor nicht.

Lässt sich eine Schnittstelle nicht exklusiv übernehmen, nennt das Menü den Return-Code (hex) und – nur wenn wirklich
vorhanden – einen zweiten TouchBridge-Prozess oder den alten LaunchAgent aus v0.1 (Menüpunkt „Alten LaunchAgent entfernen“).
Dann greift **„Systemzeiger vom Touch unterdrücken (wenn nicht exklusiv)“**: ein Event-Tap verwirft die macOS-eigenen
Maus-, Klick- und Scroll-Events dieses Geräts (Erkennung über die Absender-Registry-ID des HID-Events, sonst über
`kCGEventSourceUnixProcessID == 0` + zeitliche Nähe zu Touch-Reports; TouchBridge markiert die eigenen Events), und
TouchBridge setzt den Zeiger bei jedem Report absolut auf den Touch-Bildschirm. Im Terminal: `--no-suppress`.

## Updates
TouchBridge sucht beim Start und danach alle 24 Stunden auf GitHub nach einer neueren Version
(Menü › **Updates**: „Nach Updates suchen …“, „Automatisch prüfen“, „Vorabversionen einbeziehen“ –
Letzteres ist an, solange alle Versionen Previews sind). Gibt es ein Update, erscheint ein Punkt (•)
neben dem Symbol in der Menüleiste und oben im Menü „Update auf … verfügbar“.

„Jetzt installieren“ lädt `TouchBridge-<version>.dmg` und `SHA256SUMS.txt` aus dem Release, prüft die
SHA-256-Prüfsumme, öffnet das DMG schreibgeschützt, prüft Bundle-ID, Version und Code-Signatur,
entfernt das Quarantäne-Attribut (die App ist nicht notarisiert), gibt den Touch-Monitor frei, ersetzt
die App (bei fehlenden Schreibrechten nach Rückfrage mit Administrator-Passwort) und startet sie neu.
„Diese Version überspringen“ blendet genau diese Version aus.

Im Terminal: `touchbridge --check-update`.

## Diagnose
Menü › **Diagnose aufzeichnen** (oder `touchbridge --diagnose`): Der Touch-Dienst läuft weiter, sendet während der
Messung aber keine Events; Schnittstellen, die er schon hält, beobachtet die Diagnose nur mit (kein zweites Öffnen,
keine zweite Callback-Registrierung). Alle übrigen HID-Interfaces des Monitors werden **nicht exklusiv** geöffnet und aufgelistet (Usage-Paare, Report-Größen,
Transport, Location-ID), der Input Mode auf Multi-Touch gesetzt (Feature-Report vorher/nachher) und 10 s lang
Rohreports und HID-Werte protokolliert – mit allen Return-Codes und den Details der DDC-Probe. Kommen keine
Reports an, steht das ausdrücklich im Ergebnis.
Zusätzlich: Code-Signatur der laufenden App (`codesign -dr-`, Leaf-Zertifikat), IOHIDCheckAccess/AXIsProcessTrusted,
andere laufende TouchBridge-Prozesse, alter LaunchAgent, Zustand je Schnittstelle, Event-Tap-Statistik und die
Halter jeder HID-Schnittstelle laut `ioreg` (Prozess-Clients mit PID, Kernel-/DriverKit-Treiber, DeviceUsagePairs,
Built-In). Hält TouchBridge selbst ein Interface doppelt, steht das als Fehler im Ergebnis.

## Installieren
1. Unter **Releases** `TouchBridge-<version>.dmg` laden (Apple Silicon und Intel, ab macOS 12).
2. DMG öffnen, **TouchBridge** auf „Programme“ ziehen.
3. Erster Start: Rechtsklick auf TouchBridge › **Öffnen** (die App ist nicht von Apple notarisiert),
   alternativ Systemeinstellungen › Datenschutz & Sicherheit › „Trotzdem öffnen“.
4. **Gerätesteuerung und Datenzugriff** (älteres macOS: **Bedienungshilfen**) und **Eingabeüberwachung** für TouchBridge erlauben.

Danach sitzt das TouchBridge-Symbol (Bildschirm mit drei Berührungspunkten) in der Menüleiste.

## Menüleiste
- **Touch aktiv** an/aus, Status des erkannten Touch-Monitors
- **Modus**: Maus & Gesten oder MIDI; **MIDI-Einstellungen**: Layout, MPE, MIDI-Kanal, Grundnote, Skala,
  Pitch-Bend-Bereich, Overlay an/aus
- **Bild**: Helligkeit, Kontrast, Lautstärke per DDC/CI (Apple-Silicon-Macs, wenn der Monitor DDC kann),
  dazu Software-Abdunkeln für jeden Bildschirm
- **Touch**: Ziel-Bildschirm, Ausrichtung (0/90/180/270°, spiegeln), Scrollrichtung und -tempo, 1-Finger-Ziehen scrollt,
  exklusiver Modus, „Exklusiv nur Touch-Schnittstelle“ (Test)
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
swift test                       # Unit-Tests (Descriptor-Parser, Frames, Gesten, MIDI/MPE)
scripts/package.sh dev           # TouchBridge.app als DMG nach dist/
```

App-Icon (Entwurf „Multitouch“, Liquid Glass) und Menüleisten-Glyph werden mit
`python3 scripts/icon/make_icon.py` (pip: `cairosvg pillow`) nach `Resources/` erzeugt und sind eingecheckt.

## Aufbau
- `Sources/TouchBridgeCore` – HID-Descriptor-Parser, Frame-Zusammenbau (inkl. Hybrid-Modus), Gesten-Engine, Mapping, DDC-Pakete,
  `MIDI/` (Layouts, Finger-Tracker, MPE-Kanalvergabe, MIDI-Engine – plattformneutral, voll getestet)
- `Sources/TouchBridgeKit` – IOKit-HID-Dienst, Bildschirme, Bildsteuerung (DDC über IOAVService / Gamma), CoreMIDI-Port, Rechte
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
