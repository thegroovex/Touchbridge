# TouchBridge – technische Notizen (Deutsch)

Details für Entwickler: Berechtigungen/Signatur, exklusiver Zugriff, Single-/Multitouch-Erkennung, Experimente, Diagnose, Code-Aufbau.

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

**Multitouch-Experimente** (Menü › „Multitouch-Experimente starten …“, Terminal `touchbridge --mt-probe`
[`--skip-reenumerate`]): fünf Wege nacheinander, nach jedem 3 s Warten auf Report 13 (dabei mit 2 Fingern tippen):
a) GetReport Input 13/7 (Linux-Init), b) Feature 0x0A/0x21 lesen + Input Mode 2 über IOHID, c) die Linux-Sequenz
(SET_IDLE(0) je Interface, GET_REPORT 0x0A, GET/SET_REPORT 0x21) als direkte USB-Control-Requests (IOUSBLib, ohne
Entitlement), c') dieselbe über den Interface-Client, d) USB-Neu-Enumeration und sofort danach die Linux-Sequenz.
Der Vendor-Kanal (0xFF0A) wird nur gelesen. Die erfolgreiche Sequenz wird gespeichert und beim Verbinden automatisch
angewendet (Terminal: `--mt-sequence NAME`). Das Protokoll landet in der Zwischenablage und als
„TouchBridge-MT-Experiments.txt“ auf dem Schreibtisch.

Touch-Ziel ist immer der Anmite (Bildschirmname „ANMITE“/„A140W05T“), auch gegen eine gespeicherte Bildschirmwahl;
der integrierte Bildschirm wird nie automatisch Touch-Ziel.

**Exklusiv nur Touch-Schnittstelle** (Menü, Terminal `--seize-touch-only`) ist eine Testoption: nur der Digitizer wird
exklusiv übernommen, Maus/Vendor nicht.

Lässt sich eine Schnittstelle nicht exklusiv übernehmen, nennt das Menü den Return-Code (hex) und – nur wenn wirklich
vorhanden – einen zweiten TouchBridge-Prozess oder den alten LaunchAgent aus v0.1 (Menüpunkt „Alten LaunchAgent entfernen“).
Dann greift **„Systemzeiger vom Touch unterdrücken (wenn nicht exklusiv)“**: ein Event-Tap verwirft die macOS-eigenen
Maus-, Klick- und Scroll-Events dieses Geräts (Erkennung über die Absender-Registry-ID des HID-Events, sonst über
`kCGEventSourceUnixProcessID == 0` + zeitliche Nähe zu Touch-Reports; TouchBridge markiert die eigenen Events), und
TouchBridge setzt den Zeiger bei jedem Report absolut auf den Touch-Bildschirm. Im Terminal: `--no-suppress`.

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

## Aufbau
- `Sources/TouchBridgeCore` – HID-Descriptor-Parser, Frame-Zusammenbau (inkl. Hybrid-Modus), Gesten-Engine, Mapping, DDC-Pakete,
  `MIDI/` (Layouts, Finger-Tracker, MPE-Kanalvergabe, MIDI-Engine – plattformneutral, voll getestet)
- `Sources/TouchBridgeKit` – IOKit-HID-Dienst, Bildschirme, Bildsteuerung (DDC über IOAVService / Gamma), CoreMIDI-Port, Rechte
- `Sources/TouchBridgeApp` – Menüleisten-App
- `Sources/TouchBridge` – Kommandozeilen-Tool
- `Tests/TouchBridgeCoreTests` – XCTest mit typischen Touchscreen-Descriptoren und Gesten-Szenarien
- `.github/workflows/ci.yml` – CI: universal Build + Tests (Apple Silicon + Intel), Paket als Artefakt, Release-Upload

