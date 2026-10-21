# TouchBridge Digitizer – serial protocol (v1)

TouchBridge on the Mac talks to the dongle over its USB CDC ACM port
(`/dev/cu.usbmodem…`, USB ID `2fe3:0010`, product "TouchBridge Digitizer").
Baud rate, parity and flow control are ignored (USB full speed), except for
the **1200 baud touch** (see below). Host implementation:
`Sources/TouchBridgeCore/NRFDigitizerProtocol.swift`, firmware: `src/tb_proto.c`.

## Frame

| Byte | Field | Notes |
|------|-------|-------|
| 0 | `0xA5` | sync |
| 1 | `LEN` | payload length, 1…64 |
| 2 … LEN+1 | payload | first byte = message type |
| LEN+2 | `CRC8` | CRC-8/SMBUS (poly `0x07`, init `0x00`, no reflection) over `LEN` + payload |

A frame with a bad length or CRC is dropped; the parser waits for the next
`0xA5`. CRC check value: `crc8("123456789") = 0xF4`.

## Messages

### Host → dongle

| Type | Name | Payload after the type byte |
|------|------|-----------------------------|
| `0x01` | TOUCH | `version` (=1), `count` (0…10), `count` × contact |
| `0x02` | HELLO | – (dongle answers HELLO_REPLY) |
| `0x03` | RELEASE_ALL | – (lift every contact now) |
| `0x04` | BOOTLOADER | – (reboot into the UF2 bootloader, drive appears) |

Contact (6 bytes, little endian):

| Offset | Field | Notes |
|--------|-------|-------|
| 0 | `id` | contact identifier 0…127, stable while the finger is down |
| 1 | `flags` | bit 0 = tip (finger down), bit 1 = confidence (reserved, the HID report always sets confidence = 1) |
| 2 | `x` u16 | 0…32767, left → right of the touch surface |
| 4 | `y` u16 | 0…32767, top → bottom |

A TOUCH frame lists the contacts that are down (tip = 1). A finger that is
lifted can be sent once with tip = 0, or simply left out: the dongle lifts
every contact that was down and is missing from the frame. `count = 0` lifts
everything.

### Dongle → host

| Type | Name | Payload after the type byte |
|------|------|-----------------------------|
| `0x82` | HELLO_REPLY | `proto` (=1), `major`, `minor`, `patch`, `maxContacts` (10), `variant` (1 = s140v6 / 0x26000, 2 = s140v7 / 0x27000, 3 = nosd / 0x1000, 0 = unknown), `flags` (bit 0 BOOTLOADER message, bit 1 1200 baud touch), `load address` u32 LE, ASCII `"TBDG"` |
| `0x8F` | ERROR | `code`: 1 CRC, 2 length, 3 version, 4 unknown type |

## Timing and safety

* The host sends a TOUCH frame for every touch report (up to 120 Hz) and repeats
  the last frame at least every 100 ms while a finger is down.
* **Release timeout:** when no TOUCH frame arrives for **200 ms** while a contact
  is down, the dongle lifts all contacts.
* Closing the port (DTR 1 → 0) lifts all contacts.
* **1200 baud touch:** open the port, set 1200 baud, close it → the dongle
  reboots into the UF2 bootloader (like Arduino / nice!nano).

## HID side

The dongle re-emits every TOUCH frame as HID input report 1 of a touch screen
(usage page Digitizer `0x0D`, usage Touch Screen `0x04`), descriptor in
`src/hid_report_desc.inc`:

* 10 finger collections, each: Tip Switch, Confidence (1 bit each, 6 bit
  padding), Contact Identifier (u8), X and Y (u16, logical 0…32767, physical
  0…301.6 mm × 0…188.5 mm)
* Scan Time (u16, 100 µs units), Contact Count (u8) → 64 bytes incl. report ID
* Feature report 2: Contact Count Maximum = 10

The interrupt IN endpoint is polled every 1 ms; while a report is in flight the
newest frame replaces the waiting one (lifts are kept).
