#!/usr/bin/env bash
# TouchBridge – Anmite test on Linux (Raspberry Pi)
# Checks whether the touch controller (VID 27c0, PID 0859) delivers real multitouch on Linux,
# and records the USB enumeration with usbmon.
# Usage:  sudo bash anmite-linux-test.sh      Result: ~/anmite-linux-test.txt
set -u
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo."; exit 1; }
OUT="${SUDO_USER:+/home/$SUDO_USER}/anmite-linux-test.txt"; [ -n "${SUDO_USER:-}" ] || OUT=/root/anmite-linux-test.txt
VID=27c0; PID=0859
exec > >(tee "$OUT") 2>&1
echo "== TouchBridge Anmite Linux test $(date -Is) =="
uname -a
command -v evtest >/dev/null || { echo "Installing evtest …"; apt-get install -y evtest >/dev/null 2>&1 || true; }

echo; echo "== 1) Record USB enumeration =="
modprobe usbmon 2>/dev/null
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
MON=/sys/kernel/debug/usb/usbmon/0u
if [ -r "$MON" ]; then
  echo ">>> Now UNPLUG the Anmite touch USB-C cable from the Pi and PLUG IT BACK IN within 15 s."
  timeout 20 cat "$MON" > /tmp/usbmon.txt &
  MPID=$!
  for i in $(seq 20 -1 1); do printf "\r   %2d s left " "$i"; sleep 1; done; echo
  wait $MPID 2>/dev/null
  echo "Capture: $(wc -l < /tmp/usbmon.txt) lines"
  echo "--- usbmon (control transfers, max. 400 lines) ---"
  grep -E ' (S|C) Co:| (S|C) Ci:' /tmp/usbmon.txt | head -400
else
  echo "usbmon not available ($MON missing)"
fi
sleep 2

# Wait for the device (after re-plugging, or if it disappeared in between)
for i in $(seq 1 30); do lsusb -d $VID:$PID >/dev/null 2>&1 && break
  [ "$i" -eq 1 ] && echo ">>> Anmite not on USB – please plug in the touch USB-C (again), waiting up to 30 s …"; sleep 1; done
lsusb -d $VID:$PID >/dev/null 2>&1 || echo "!!! Anmite still NOT on USB (power/cable/OTG adapter?)"
sleep 2

echo; echo "== 2) Device & drivers =="
echo "--- lsusb ---"; lsusb
lsusb -d $VID:$PID -v 2>/dev/null | grep -E 'Bus|iManufacturer|iProduct|bInterfaceNumber|bInterfaceClass|bInterfaceProtocol|wMaxPacketSize|bInterval' || lsusb | grep -i "$VID:$PID"
echo "--- dmesg ---"
dmesg | grep -iE "$VID|0859|wch|multitouch|hid-generic|input:.*TouchScreen|usb 1-|disconnect|over-current|dwc" | tail -40
echo "--- bound HID drivers ---"
for d in /sys/bus/hid/devices/*${VID^^}:${PID^^}*; do
  [ -e "$d" ] || continue
  echo "$(basename "$d") -> $(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
done
echo "--- input devices ---"
awk -v RS= -v IGNORECASE=1 '/Vendor=27c0/' /proc/bus/input/devices

echo; echo "== 3) Multitouch test (10 s) =="
EV=$(awk -v RS= '/Vendor=27c0/ && /ABS=/' /proc/bus/input/devices | grep -o 'event[0-9]*' | head -1)
if [ -n "$EV" ]; then
  echo "Device file: /dev/input/$EV"
  evtest --info /dev/input/$EV 2>/dev/null | grep -E 'ABS_MT|Input device name|ABS_X|BTN_TOUCH' | head -20
  echo ">>> Now tap and swipe on the Anmite with 2-3 FINGERS at once for 10 s."
  timeout 10 evtest /dev/input/$EV > /tmp/evtest.txt 2>&1
  echo "Total events: $(grep -c '^Event:' /tmp/evtest.txt)"
  echo "ABS_MT_SLOT events: $(grep -c 'ABS_MT_SLOT' /tmp/evtest.txt)  highest slot: $(grep 'ABS_MT_SLOT' /tmp/evtest.txt | grep -o 'value [0-9]*' | awk '{print $2}' | sort -n | tail -1)"
  echo "ABS_MT_TRACKING_ID: $(grep -c 'ABS_MT_TRACKING_ID' /tmp/evtest.txt)"
  echo "--- first 40 events ---"; grep '^Event:' /tmp/evtest.txt | head -40
else
  echo "No input device with absolute axes found."
fi

echo; echo "== 4) Raw HID reports (hidraw, 5 s) =="
for h in /sys/class/hidraw/hidraw*; do
  grep -qi "${VID}" "$h/device/uevent" 2>/dev/null || continue
  n=$(basename "$h"); echo "--- /dev/$n ($(grep HID_PHYS "$h/device/uevent" | cut -d= -f2)) ---"
  echo ">>> tap …"; timeout 5 xxd -c 64 /dev/$n 2>/dev/null | head -8
done
echo; echo "Done. File: $OUT"
