#!/usr/bin/env bash
# Install / update / remove the TouchBridge Pi bridge (Bluetooth)
#   Install:    curl -fsSL https://raw.githubusercontent.com/thegroovex/Touchbridge/main/scripts/pi/install-bt-bridge.sh | sudo bash
#   Remove:        sudo bash install-bt-bridge.sh --uninstall
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo."; exit 1; }
RAW=https://raw.githubusercontent.com/thegroovex/Touchbridge/main/scripts/pi/bt-bridge
DROPIN=/etc/systemd/system/bluetooth.service.d/touchbridge.conf
UNIT=/etc/systemd/system/touchbridge-bt.service

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now touchbridge-bt 2>/dev/null || true
  rm -f "$UNIT" "$DROPIN"; rm -rf /opt/touchbridge
  systemctl daemon-reload; systemctl restart bluetooth
  echo "Pi bridge removed."; exit 0
fi

echo "== Packages =="
apt-get update -qq
apt-get install -y -qq bluez python3-dbus python3-gi >/dev/null
rfkill unblock bluetooth 2>/dev/null || true

echo "== Program =="
mkdir -p /opt/touchbridge /var/lib/touchbridge
curl -fsSL "$RAW/tb_bt_bridge.py" -o /opt/touchbridge/tb_bt_bridge.py
chmod 755 /opt/touchbridge/tb_bt_bridge.py

echo "== bluetoothd without input plugin (otherwise it grabs the HID channels) =="
BTD=$(for p in /usr/libexec/bluetooth/bluetoothd /usr/lib/bluetooth/bluetoothd; do [ -x "$p" ] && echo "$p" && break; done)
[ -n "$BTD" ] || { echo "bluetoothd not found"; exit 1; }
mkdir -p "$(dirname "$DROPIN")"
cat > "$DROPIN" <<CONF
[Service]
ExecStart=
ExecStart=$BTD --noplugin=input
CONF
# Device class: peripheral/pointing device, name
if grep -q '^#\?Class' /etc/bluetooth/main.conf; then
  sed -i 's/^#\?Class *=.*/Class = 0x002580/' /etc/bluetooth/main.conf
else
  sed -i '/^\[General\]/a Class = 0x002580' /etc/bluetooth/main.conf
fi
if grep -q '^#\?Name *=' /etc/bluetooth/main.conf; then
  sed -i 's/^#\?Name *=.*/Name = Anmite Touch (TouchBridge)/' /etc/bluetooth/main.conf
else
  sed -i '/^\[General\]/a Name = Anmite Touch (TouchBridge)' /etc/bluetooth/main.conf
fi

echo "== USB stability (Pi Zero / Pi 1) =="
REBOOT=0
CMD=/boot/firmware/cmdline.txt; [ -f "$CMD" ] || CMD=/boot/cmdline.txt
if [ -d /sys/module/dwc_otg ] && ! grep -q "dwc_otg.speed=1" "$CMD"; then
  # The Anmite touch is a full-speed device; behind a hub dwc_otg otherwise chokes now and then (hub reset)
  cp "$CMD" "$CMD.bak"
  sed -i '1 s/$/ dwc_otg.speed=1/' "$CMD"
  REBOOT=1
  echo "dwc_otg.speed=1 set (takes effect after reboot)"
fi

echo "== Service =="
cat > "$UNIT" <<UNITEOF
[Unit]
Description=TouchBridge Pi bridge (Anmite multitouch -> Bluetooth HID)
After=bluetooth.service
Requires=bluetooth.service

[Service]
ExecStart=/usr/bin/python3 /opt/touchbridge/tb_bt_bridge.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl restart bluetooth
sleep 2
systemctl enable touchbridge-bt >/dev/null 2>&1
systemctl restart touchbridge-bt
sleep 3
journalctl -u touchbridge-bt -n 15 --no-pager
echo
echo "Done. On your Mac: System Settings › Bluetooth › \"Anmite Touch (TouchBridge)\" › Connect."
echo "Log live:  journalctl -u touchbridge-bt -f"
if [ "$REBOOT" = 1 ]; then echo; echo ">>> Please reboot once: sudo reboot"; fi
