# TouchBridge Digitizer firmware (nRF52840 dongle)

Turns a "Pro Micro nRF52840" / nice!nano v2 compatible board into a USB
multitouch digitizer for the Mac:

```
Anmite touch ──USB──▶ Mac (TouchBridge reads it exclusively)
                         │ contact frames, USB CDC ACM (PROTOCOL.md)
                         ▼
                  nRF52840 dongle ──USB HID touch screen──▶ macOS
```

TouchBridge keeps reading the Anmite and forwards the finger positions to the
dongle; the dongle reports them to macOS as a real USB HID touch screen
(digitizer usage page `0x0D`, Touch Screen `0x04`, 10 contacts). TouchBridge
posts no synthetic gestures or mouse events in this mode – macOS handles the
touches itself.

USB ID `2fe3:0010`, product "TouchBridge Digitizer", one configuration with a
CDC ACM port (`/dev/cu.usbmodem…`) and a HID interface. Zephyr v4.4.2,
device_next USB stack, board `promicro_nrf52840`.

## Which file?

The CI artefact **`touchbridge-digitizer-uf2`** (and each GitHub release) contains
three builds – they differ only in the flash address the bootloader expects:

| `INFO_UF2.TXT` on the bootloader drive says | file |
|---|---|
| `SoftDevice: S140 version 6.x.x` (original nice!nano bootloader) | `touchbridge-digitizer-s140v6-0x26000.uf2` |
| `SoftDevice: S140 version 7.x.x` | `touchbridge-digitizer-s140v7-0x27000.uf2` |
| `SoftDevice: not found` | `touchbridge-digitizer-nosd-0x1000.uf2` |

The Ulegqin boards seen so far ship the S140 v6 bootloader. If you already use
the same board for the Auracaster dongle, pick the same variant as there.

## Flashing

1. Plug the board into the Mac.
2. **Double reset:** short `RST` to `GND` twice within half a second (tweezers or a
   button). The red LED pulses and a drive named `NICENANO` (or similar) appears.
3. Open `INFO_UF2.TXT` on the drive and pick the matching file (table above).
4. Copy the `.uf2` onto the drive (Finder or `cp touchbridge-digitizer-….uf2 /Volumes/NICENANO/`).
   The drive disappears by itself when the copy is done; macOS may warn that the
   disk was not ejected properly – that is normal.
5. The board restarts as "TouchBridge Digitizer". Check with
   `ioreg -p IOUSB -l | grep -i "TouchBridge Digitizer"` or System Information › USB.

Later updates: once this firmware runs, TouchBridge (or any terminal) can send it
to the bootloader without touching the reset pin – "1200 baud touch":
`stty -f /dev/cu.usbmodem<…> 1200` – or the BOOTLOADER message (PROTOCOL.md).

## Status LED (P0.15, red)

| LED | meaning |
|---|---|
| short blip every 2 s | no USB host / not configured |
| slow blink (1 Hz) | USB ok, TouchBridge has not opened the port |
| steady on | TouchBridge connected |
| fast blink (5 Hz) | finger(s) down |

## Using it with TouchBridge

Menu bar › **Output › Digitizer dongle (macOS handles touch)** (or Settings ›
General › Output). The menu shows `Digitizer dongle: connected (firmware 0.1.0, s140v6)`.
In this mode TouchBridge only forwards contacts; gestures, smart target and the
touch context menu are macOS' job. MIDI mode is unaffected.

**Coordinate space** (menu Output › Dongle covers): the dongle reports 0…32767 over
its whole surface. macOS decides which screen a USB touch screen belongs to – this is
the main open question. Default "Touch display" assumes macOS maps it onto the Anmite;
if touches land on the wrong screen, try "Main display" or "All displays" (TouchBridge
then converts the Anmite position into that space).

## Building locally

```
pip install west
west init -l firmware/nrf-digitizer   # inside an empty workspace with a copy of firmware/nrf-digitizer
west update --narrow -o=--depth=1
west build -b promicro_nrf52840/nrf52840/uf2 nrf-digitizer                                   # s140v6
west build -b promicro_nrf52840/nrf52840/uf2 nrf-digitizer -- -DEXTRA_DTC_OVERLAY_FILE=$PWD/nrf-digitizer/sdv7.overlay   # s140v7
west build -b promicro_nrf52840/nrf52840 nrf-digitizer                                       # nosd
```

Host test of the protocol parser and report builder (no Zephyr needed):

```
cd firmware/nrf-digitizer/tests
cc -std=c11 -Wall -Wextra -Werror -I../src ../src/tb_proto.c ../src/tb_report.c proto_test.c -o proto_test && ./proto_test
```
