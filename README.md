# TouchBridge – use the Anmite touchscreen on your Mac

[![CI](https://github.com/thegroovex/Touchbridge/actions/workflows/ci.yml/badge.svg)](https://github.com/thegroovex/Touchbridge/actions/workflows/ci.yml)

macOS does not support touchscreens. TouchBridge is a small menu bar app that reads the touch data of the
**Anmite A140W05T** portable monitor (14", USB-C) and turns your fingers into clicks, scrolling, zooming and
gestures. It can also turn the screen into a **MIDI controller** for Ableton Live and other music apps.

There are two ways to use it:

| | **Simple setup** | **Multitouch setup** |
|---|---|---|
| What you get | Single touch: tap, drag, hold for right-click | Real 10-finger multitouch: two-finger scroll, pinch zoom, 3-finger swipes, MIDI with many fingers |
| What you need | Just the monitor and one USB-C cable | Monitor + a Raspberry Pi (e.g. Pi Zero W) + HDMI cable |
| Setup time | 5 minutes | about 30 minutes, once |

Why the Pi? The monitor's firmware only sends multitouch data to Windows, Android and Linux. On a Mac it falls
back to a simple "mouse" mode. The Pi runs Linux, receives the real multitouch data and forwards it to your Mac
over Bluetooth. TouchBridge detects both setups automatically – you can switch between them at any time just by
re-plugging cables.

---

## 1. Install the app on your Mac

1. Download the latest `TouchBridge-<version>.dmg` from
   [Releases](https://github.com/thegroovex/Touchbridge/releases) (works on Apple Silicon and Intel, macOS 12 or newer).
2. Open the DMG and drag **TouchBridge** into **Applications**.
3. First launch: right-click TouchBridge in Applications › **Open** › **Open**.
   (The app is not notarized by Apple, so macOS asks once. Alternatively: System Settings › Privacy & Security ›
   "Open Anyway".)
4. macOS asks for two permissions – allow both:
   - **Input Monitoring** (so TouchBridge can read the touchscreen)
   - **Accessibility** (called **"Device control and data access"** on macOS 27) – so TouchBridge can click and scroll

You now have the TouchBridge icon (a screen with three touch points) in your menu bar.
TouchBridge updates itself: when a new version is out, a dot (•) appears next to the icon – open the menu and
choose **Install now**.

## 2a. Simple setup (single touch)

Connect the monitor to your Mac with **one USB-C cable** (picture and touch over the same cable). That's it.
The menu shows **Source: Single touch**.

## 2b. Multitouch setup with a Raspberry Pi

### What you need

- A **Raspberry Pi with Bluetooth**: Pi Zero W / Zero 2 W (cheap and tiny), or Pi 3 / 4 / 5
- A **microSD card** (8 GB or more) and a way to write it from your Mac
- A **power supply** for the Pi
- A cable from the monitor's **USB-C** port to the Pi:
  - Pi Zero: a **USB-C to micro-USB OTG** cable, or a small USB hub/OTG adapter + the monitor's USB-C cable
    (use the Pi Zero's port labelled **USB**, not **PWR**)
  - Pi 3/4/5: a normal USB-C to USB-A cable
- An **HDMI cable** from your Mac to the monitor's HDMI port (with an adapter if your Mac has no HDMI)
- Power for the monitor (its own power supply on its second USB-C port)

### How it is wired

```
 Mac ── HDMI ─────────────────────► Anmite monitor   (picture)
 Anmite USB-C (touch) ────────────► Raspberry Pi    (touch data)
 Raspberry Pi ── Bluetooth ───────► Mac             (multitouch)
```

Important: the monitor switches itself off after about 30 seconds when it gets **no picture** ("NO SIGNAL") –
and the touch goes off with it. So always connect HDMI from the Mac first.

### Step 1 – Prepare the SD card

1. Install **Raspberry Pi Imager** on your Mac: <https://www.raspberrypi.com/software/>
2. Open it and choose:
   - **Device:** your Pi model
   - **Operating system:** *Raspberry Pi OS (other)* › **Raspberry Pi OS Lite** (32-bit for Pi Zero W, 64-bit for others)
   - **Storage:** your SD card
3. Click **Next** › **Edit settings** and set:
   - hostname: `anmite-pi`
   - a username and password (remember them)
   - your Wi-Fi name and password, and your country
   - on the **Services** tab: turn on **SSH** with password authentication
4. Write the card, put it into the Pi and power the Pi on. Wait 2–3 minutes for the first boot.

Wi-Fi is only needed for this setup. Afterwards the bridge works anywhere, over Bluetooth only.

### Step 2 – Install the bridge on the Pi

1. On your Mac, open **Terminal** and log in to the Pi (use your username):
   ```bash
   ssh yourname@anmite-pi.local
   ```
   Type `yes` when asked about the fingerprint, then your password.
2. Copy and paste this one line and press Enter:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/thegroovex/Touchbridge/main/scripts/pi/install-bt-bridge.sh | sudo bash
   ```
   It installs everything and starts the bridge automatically on every boot.
3. If the installer says **"Please reboot once"**, run `sudo reboot` and log in again after a minute.

### Step 3 – Connect everything

1. Connect **HDMI** from the Mac to the monitor and make sure you see a picture.
2. Plug the monitor's **USB-C** (touch) into the Pi.
3. On your Mac: **System Settings › Bluetooth**, find **"Anmite Touch (TouchBridge)"** and click **Connect**.
4. Start TouchBridge. The menu should show **Anmite Touch (TouchBridge)** and **Source: Multitouch**.
   Try scrolling with two fingers.

From now on: power on the Pi, connect HDMI – the Pi reconnects to your Mac by itself.

### Updating the Pi

Run the same install line again (step 2.2). It updates the bridge and keeps your pairing.
To remove it: `curl -fsSL https://raw.githubusercontent.com/thegroovex/Touchbridge/main/scripts/pi/install-bt-bridge.sh | sudo bash -s -- --uninstall`

## 2c. Experimental: nRF52840 digitizer dongle (macOS handles touch)

Instead of TouchBridge turning touches into synthetic mouse/gesture events, a small **nRF52840 board** plugged into
the Mac can present the touches to macOS as a **real USB touch screen**. macOS 27 treats real HID digitizers as
direct touch (pointer hidden, Apple's touch emulation – TN3212), which synthetic events cannot achieve.

```
Anmite touch ──USB──▶ Mac (TouchBridge) ──USB serial──▶ nRF52840 dongle ──USB HID touch screen──▶ macOS
```

1. **Board:** "Pro Micro nRF52840" (nice!nano v2 clone, UF2 bootloader), e.g. the one used for the Auracaster dongle.
2. **Firmware:** download `touchbridge-digitizer-*.uf2` from the release (or the CI artefact
   `touchbridge-digitizer-uf2`). Double-reset the board (short RST–GND twice), open `INFO_UF2.TXT` on the drive and copy
   the matching file: S140 6.x → `s140v6-0x26000`, S140 7.x → `s140v7-0x27000`, "not found" → `nosd-0x1000`.
   Details, LED codes and the serial protocol: [firmware/nrf-digitizer](firmware/nrf-digitizer/README.md).
3. Keep the Anmite's USB on the Mac as before and plug the dongle into the Mac as well.
4. Menu › **Output › Digitizer dongle (macOS handles touch)**. The menu shows
   *Digitizer dongle: connected (firmware 0.1.0, …)*. TouchBridge now only forwards finger positions (up to 120 Hz,
   10 fingers); it posts **no** gestures or mouse events of its own. If the dongle is missing nothing happens –
   switch back to **Gestures (synthetic events)**.
5. **Which screen?** macOS decides which display a USB touch screen belongs to. If touches land on the wrong
   screen, try Menu › Output › **Dongle covers › Main display** or **All displays**.

CLI: `touchbridge --digitizer [--digitizer-space touch|main|all]`.

---

## Gestures

| Gesture | Action |
|---|---|
| Tap with 1 finger | Click (tap twice = double-click); taps just next to a button, checkbox, link or field snap onto it (Smart target) |
| Drag with 1 finger | Drag / select / move windows |
| Hold 1 finger (~0.5 s) | Touch context menu: the item's own menu, or large rows with its actions plus Copy / Paste / Right click |
| Tap with 2 fingers | Right-click (after a short pause, so a double tap can be recognised) * |
| Double-tap with 2 fingers | Smart zoom * |
| Slide 2 fingers | Scroll with momentum and rubber-banding, like a trackpad * |
| Pinch / spread 2 fingers | Zoom, like on a trackpad (Maps, Photos, Safari, Preview …) * |
| Rotate 2 fingers | Rotate (Photos, Preview, Maps …) * |
| Swipe 3 or 4 fingers left / right | Switch desktop (Space) * |
| Swipe 3 or 4 fingers up / down | Mission Control / App Exposé * |
| Pinch 4–5 fingers together | Launchpad (Apps on macOS 26+) * |
| Spread 4–5 fingers | Show desktop * |

\* needs the multitouch setup.

Menu options: **Language** (English/Deutsch), **1-finger drag scrolls** (instead of dragging), **Pinch = trackpad zoom** (off: sends Cmd + / Cmd −
instead), **Momentum scrolling**, **Hide pointer while touching** (comes back when you move a real mouse or trackpad), scroll direction and
speed, screen orientation (Touch › Orientation). **Touch › Gestures** lists which gesture does what.

**Settings … (⌘,)** opens the settings window: *General* (the toggles above, language), *Gestures* (choose an action for every
gesture: system actions, click / right click / middle click, a recorded keyboard shortcut, open an app, or nothing; *Reset to
defaults*), *Touch* (Smart target on/off and search radius, touch context menu on/off, hold time) and *About*. Smart target and the
touch context menu need the Accessibility permission. Mission Control, App Exposé and Spaces use
the system shortcuts Ctrl ↑ / Ctrl ↓ / Ctrl ← → and Show desktop uses F11 – keep them enabled in System Settings › Keyboard › Keyboard Shortcuts.

**App profiles** (Settings › *Profiles*): give an app its own gestures and settings (pinch zoom, scroll direction and speed,
1-finger scroll, momentum, smart target, touch context menu, hold time – each either *Default* or its own value). Add a profile
with **+** (a running app or an .app file), duplicate or delete it, and edit it with the same gesture editor. TouchBridge switches
automatically when that app comes to the front; every other app uses the *Default* profile (the normal settings). Menu ›
**Profile** chooses *Automatic*, *Default* or a fixed profile (manual profiles without an app live there too). *Export …* /
*Import …* save and load profiles as a versioned JSON file; importing replaces the profile of the same app and adds the rest.

## MIDI mode

Menu › **Mode › MIDI** turns the screen into a MIDI controller. TouchBridge creates a virtual MIDI port
called **"TouchBridge"** and shows a see-through overlay with faders, pads, an XY field or keys on the touchscreen.

| Layout | Contents | MIDI |
|---|---|---|
| `mixer` | 8 faders on top, 8 pads below | faders CC 20–27, pads from the base note |
| `keyboard` | 2 rows of keys (MPE keyboard) | notes from the base note, selectable scale |
| `performance` | 4 faders, XY field, 8 pads | faders CC 20–23, XY = CC 16 / CC 17, pads |

- Every finger stays in the zone where it touched down (up to 10 fingers at once).
- **MPE** (on by default, keyboard layout): every note on its own channel; slide sideways = pitch bend,
  up/down within a key = CC 74.
- Settings in Menu › **MIDI settings**: layout, MPE, channel, base note, scale, pitch bend range, overlay.

**Ableton Live:** Settings › Link, Tempo & MIDI › enable **Track** and **Remote** for input "TouchBridge".
Map faders with Cmd+M. For MPE (Live 11/12) use the keyboard layout with an MPE-capable instrument
(Drift, Meld, Wavetable …) and set the track input to "TouchBridge" › MPE.

**Ohpe / livelooper:** enable "TouchBridge" as MIDI input (standalone) or as the track input (plug-in) and use
MIDI learn. Turn MPE off (`--no-mpe`) when you want everything on one channel.

## Monitor controls

Menu › **Picture**: brightness, contrast and volume of the monitor via DDC (Apple Silicon), plus extra software dimming.

## Troubleshooting

| Problem | Fix |
|---|---|
| Menu says nothing is connected | Check the cable, then Menu › Permissions – both permissions must be allowed. After an update you may need to remove TouchBridge from both permission lists with "–" and add it again (or Menu › Permissions › Reset permissions). |
| Touch lands on the wrong screen or rotated | Menu › Touch › Screen / Orientation |
| Multitouch: nothing happens | Is there a picture on the monitor? Is "Anmite Touch (TouchBridge)" connected in Bluetooth settings? On the Pi run `journalctl -u touchbridge-bt -f` – you should see "Reading touch reports" and one line per touch. |
| Multitouch stops for a while, then works again | Usually USB trouble between monitor and Pi. Run the installer again (it sets a USB stability fix) and reboot the Pi, or connect the monitor to the Pi without a hub. |
| `ssh: Could not resolve hostname anmite-pi.local` | Wait a bit longer after the first boot, check the Wi-Fi settings in Raspberry Pi Imager, or use the Pi's IP address from your router. |
| Bluetooth device does not appear on the Mac | On the Pi: `sudo systemctl restart bluetooth touchbridge-bt`, then look again. To pair from scratch, remove the device on the Mac first. |

For a detailed report: Menu › **Record diagnostics** (touch the screen for 10 s). The result is copied to the
clipboard and saved as `TouchBridge-Diagnostics.txt` on your desktop – attach it to an
[issue](https://github.com/thegroovex/Touchbridge/issues).

## Real touch experiment (0.4 beta)

Experimental, for testing on macOS 27: can macOS be made to deliver *real* touches (like Sidecar) instead of mouse events?

- Menu › **Touch test window …** – a window that counts what apps receive: direct touches (real screen touches),
  indirect touches (trackpad style), gesture recognizers, mouse and gesture events.
- Menu › **Real touch experiment …** – opens the test window on the touch display and plays a tap, a drag and a
  2-finger pinch in 5 variants (synthetic events with an attached HID digitizer payload, private macOS API).
  Results are appended to `TouchBridge-RealTouch-Probe.txt` on your desktop. CLI: `touchbridge --touch-probe`.
- Menu › **Bluetooth digitizer: let macOS handle it** – TouchBridge releases the Pi bridge so you can see in the test
  window whether macOS handles the Bluetooth touchscreen by itself. Turn it off again to get TouchBridge back.

## Command line

Menu › **Install command line tool** links `touchbridge` to `/usr/local/bin`. Examples:
`touchbridge --list-displays`, `touchbridge --dump`, `touchbridge --rotate 90`, `touchbridge --brightness 60`,
`touchbridge --midi --layout keyboard`. All options: `touchbridge --help`.

## Build it yourself

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
swift build -c release
swift test                       # unit tests (descriptor parser, frames, gestures, MIDI/MPE)
scripts/package.sh dev           # builds TouchBridge.app as a DMG in dist/
```

Technical background (permissions and code signing, exclusive device access, single/multitouch detection,
experiments, diagnostics, code layout): [docs/technical-notes.de.md](docs/technical-notes.de.md) (German).

The app is in English by default. For German choose Menu › **Language › Deutsch**.
