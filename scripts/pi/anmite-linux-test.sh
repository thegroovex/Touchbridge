#!/usr/bin/env bash
# TouchBridge – Anmite-Test unter Linux (Raspberry Pi)
# Prüft, ob der Touch-Controller (VID 27c0, PID 0859) unter Linux echtes Multitouch liefert,
# und schneidet die USB-Anmeldung (Enumeration) mit usbmon mit.
# Aufruf:  sudo bash anmite-linux-test.sh      Ergebnis: ~/anmite-linux-test.txt
set -u
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten."; exit 1; }
OUT="${SUDO_USER:+/home/$SUDO_USER}/anmite-linux-test.txt"; [ -n "${SUDO_USER:-}" ] || OUT=/root/anmite-linux-test.txt
VID=27c0; PID=0859
exec > >(tee "$OUT") 2>&1
echo "== TouchBridge Anmite-Linux-Test $(date -Is) =="
uname -a
command -v evtest >/dev/null || { echo "Installiere evtest …"; apt-get install -y evtest >/dev/null 2>&1 || true; }

echo; echo "== 1) USB-Anmeldung mitschneiden =="
modprobe usbmon 2>/dev/null
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
MON=/sys/kernel/debug/usb/usbmon/0u
if [ -r "$MON" ]; then
  echo ">>> Jetzt das Touch-USB-C-Kabel des Anmite vom Pi ABZIEHEN und innerhalb von 15 s WIEDER EINSTECKEN."
  timeout 20 cat "$MON" > /tmp/usbmon.txt &
  MPID=$!
  for i in $(seq 20 -1 1); do printf "\r   noch %2d s " "$i"; sleep 1; done; echo
  wait $MPID 2>/dev/null
  echo "Mitschnitt: $(wc -l < /tmp/usbmon.txt) Zeilen"
  echo "--- usbmon (Control-Transfers, max. 400 Zeilen) ---"
  grep -E ' (S|C) Co:| (S|C) Ci:' /tmp/usbmon.txt | head -400
else
  echo "usbmon nicht verfügbar ($MON fehlt)"
fi
sleep 2

echo; echo "== 2) Gerät & Treiber =="
lsusb -d $VID:$PID -v 2>/dev/null | grep -E 'Bus|iManufacturer|iProduct|bInterfaceNumber|bInterfaceClass|bInterfaceProtocol|wMaxPacketSize|bInterval' || lsusb | grep -i "$VID:$PID"
echo "--- dmesg ---"
dmesg | grep -iE "$VID|0859|wch|multitouch|hid-generic|input:.*TouchScreen" | tail -30
echo "--- gebundene HID-Treiber ---"
for d in /sys/bus/hid/devices/*${VID^^}:${PID^^}*; do
  [ -e "$d" ] || continue
  echo "$(basename "$d") -> $(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
done
echo "--- Input-Geräte ---"
awk -v RS= -v IGNORECASE=1 '/Vendor=27c0/' /proc/bus/input/devices

echo; echo "== 3) Multitouch-Test (10 s) =="
EV=$(awk -v RS= '/Vendor=27c0/ && /ABS=/' /proc/bus/input/devices | grep -o 'event[0-9]*' | head -1)
if [ -n "$EV" ]; then
  echo "Geräte-Datei: /dev/input/$EV"
  evtest --info /dev/input/$EV 2>/dev/null | grep -E 'ABS_MT|Input device name|ABS_X|BTN_TOUCH' | head -20
  echo ">>> Jetzt 10 s lang mit 2-3 FINGERN gleichzeitig auf das Anmite tippen und wischen."
  timeout 10 evtest /dev/input/$EV > /tmp/evtest.txt 2>&1
  echo "Events gesamt: $(grep -c '^Event:' /tmp/evtest.txt)"
  echo "ABS_MT_SLOT-Events: $(grep -c 'ABS_MT_SLOT' /tmp/evtest.txt)  höchster Slot: $(grep 'ABS_MT_SLOT' /tmp/evtest.txt | grep -o 'value [0-9]*' | awk '{print $2}' | sort -n | tail -1)"
  echo "ABS_MT_TRACKING_ID: $(grep -c 'ABS_MT_TRACKING_ID' /tmp/evtest.txt)"
  echo "--- erste 40 Events ---"; grep '^Event:' /tmp/evtest.txt | head -40
else
  echo "Kein Input-Gerät mit Absolutachsen gefunden."
fi

echo; echo "== 4) Rohe HID-Reports (hidraw, 5 s) =="
for h in /sys/class/hidraw/hidraw*; do
  grep -qi "${VID}" "$h/device/uevent" 2>/dev/null || continue
  n=$(basename "$h"); echo "--- /dev/$n ($(grep HID_PHYS "$h/device/uevent" | cut -d= -f2)) ---"
  echo ">>> tippen …"; timeout 5 xxd -c 64 /dev/$n 2>/dev/null | head -8
done
echo; echo "Fertig. Datei: $OUT"
