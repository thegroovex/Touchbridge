#!/usr/bin/env python3
"""TouchBridge Pi bridge: Anmite multitouch (USB, Linux hid-multitouch) -> Bluetooth HID -> Mac.

The Pi presents itself over Bluetooth as an HID touchscreen with the same VID/PID (0x27C0/0x0859) and the same
report descriptor as the Anmite's touch interface. The raw reports (report 13, 10 fingers) are forwarded
unchanged from /dev/hidrawN, so TouchBridge on the Mac recognises the device just like the real Anmite.

Linux (hid-multitouch) switches the controller into multitouch mode by itself when plugged in – so the kernel
driver stays bound; we only read in parallel via hidraw.
"""
import fcntl, glob, json, os, select, socket, struct, sys, threading, time

import dbus, dbus.service, dbus.mainloop.glib
from gi.repository import GLib

VID, PID = 0x27C0, 0x0859
NAME = "Anmite Touch (TouchBridge)"
STATE_DIR = "/var/lib/touchbridge"
DESC_CACHE = os.path.join(STATE_DIR, "descriptor.bin")
HOST_FILE = os.path.join(STATE_DIR, "host.json")
PSM_CTRL, PSM_INTR = 17, 19
PROFILE_UUID = "00001124-0000-1000-8000-00805f9b34fb"  # HID
AGENT_PATH = "/touchbridge/agent"
PROFILE_PATH = "/touchbridge/profile"

# Fallback descriptor (reconstructed from the macOS diagnostics) in case the Anmite is not connected at startup
def _fallback_descriptor():
    h = lambda s: bytes.fromhex(s.replace(" ", ""))
    finger = ("09 22 A1 02 09 42 15 00 25 01 75 01 95 01 81 02 95 03 81 01 09 51 75 04 25 0F 95 01 81 02 05 01 26 FF 3F"
              " 75 10 55 0E 65 11 09 30 35 00 46 79 08 81 02 26 7F 25 46 8A 03 09 31 81 02 05 0D C0")
    d = h("05 0D 09 04 A1 01 85 0D") + h(finger) * 10
    d += h("27 FF FF 00 00 75 10 95 01 09 56 81 02 09 54 15 00 25 7F 95 01 75 08 81 02 85 0A 09 55 95 01 25 0F B1 02 C0")
    d += h("05 0D 09 0E A1 01 85 21 09 22 A1 00 09 52 09 53 15 00 25 0A 75 08 95 02 B1 02 C0 C0")
    return d

def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)

# ---------------------------------------------------------------- Anmite (hidraw)

def find_hidraw():
    """hidraw of the Anmite touch interface (interface 0, digitizer)"""
    for h in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            ue = open(os.path.join(h, "device/uevent")).read().upper()
        except OSError:
            continue
        if f"{VID:08X}:{PID:08X}" not in ue:
            continue
        try:
            desc = open(os.path.join(h, "device/report_descriptor"), "rb").read()
        except OSError:
            continue
        if desc[:4] == bytes.fromhex("050D0904"):  # Digitizer / Touch Screen
            return "/dev/" + os.path.basename(h), desc
    return None, None

def load_descriptor():
    _, desc = find_hidraw()
    if desc:
        os.makedirs(STATE_DIR, exist_ok=True)
        if not os.path.exists(DESC_CACHE) or open(DESC_CACHE, "rb").read() != desc:
            open(DESC_CACHE, "wb").write(desc)
        log(f"Descriptor read from the Anmite ({len(desc)} bytes)")
        return desc
    if os.path.exists(DESC_CACHE):
        log("Anmite not connected – using saved descriptor")
        return open(DESC_CACHE, "rb").read()
    log("Anmite not connected – using built-in descriptor")
    return _fallback_descriptor()

# ---------------------------------------------------------------- SDP-Record

def sdp_record(desc: bytes) -> str:
    dhex = desc.hex()
    return f"""<?xml version="1.0" encoding="UTF-8" ?>
<record>
  <attribute id="0x0001"><sequence><uuid value="0x1124" /></sequence></attribute>
  <attribute id="0x0004"><sequence>
    <sequence><uuid value="0x0100" /><uint16 value="0x0011" /></sequence>
    <sequence><uuid value="0x0011" /></sequence></sequence></attribute>
  <attribute id="0x0005"><sequence><uuid value="0x1002" /></sequence></attribute>
  <attribute id="0x0006"><sequence><uint16 value="0x656e" /><uint16 value="0x006a" /><uint16 value="0x0100" /></sequence></attribute>
  <attribute id="0x0009"><sequence><sequence><uuid value="0x1124" /><uint16 value="0x0100" /></sequence></sequence></attribute>
  <attribute id="0x000d"><sequence><sequence>
    <sequence><uuid value="0x0100" /><uint16 value="0x0013" /></sequence>
    <sequence><uuid value="0x0011" /></sequence></sequence></sequence></attribute>
  <attribute id="0x0100"><text value="{NAME}" /></attribute>
  <attribute id="0x0101"><text value="Multitouch bridge" /></attribute>
  <attribute id="0x0102"><text value="groovex" /></attribute>
  <attribute id="0x0200"><uint16 value="0x0100" /></attribute>
  <attribute id="0x0201"><uint16 value="0x0111" /></attribute>
  <attribute id="0x0202"><uint8 value="0x80" /></attribute>
  <attribute id="0x0203"><uint8 value="0x00" /></attribute>
  <attribute id="0x0204"><boolean value="false" /></attribute>
  <attribute id="0x0205"><boolean value="true" /></attribute>
  <attribute id="0x0206"><sequence><sequence><uint8 value="0x22" /><text encoding="hex" value="{dhex}" /></sequence></sequence></attribute>
  <attribute id="0x0207"><sequence><sequence><uint16 value="0x0409" /><uint16 value="0x0100" /></sequence></sequence></attribute>
  <attribute id="0x020b"><uint16 value="0x0100" /></attribute>
  <attribute id="0x020c"><uint16 value="0x0c80" /></attribute>
  <attribute id="0x020d"><boolean value="false" /></attribute>
  <attribute id="0x020e"><boolean value="true" /></attribute>
  <attribute id="0x020f"><uint16 value="0x0640" /></attribute>
  <attribute id="0x0210"><uint16 value="0x0320" /></attribute>
</record>"""

# ---------------------------------------------------------------- BlueZ: profile + agent

class Profile(dbus.service.Object):
    @dbus.service.method("org.bluez.Profile1", in_signature="", out_signature="")
    def Release(self): pass
    @dbus.service.method("org.bluez.Profile1", in_signature="oha{sv}", out_signature="")
    def NewConnection(self, path, fd, props): os.close(fd.take())  # we accept L2CAP directly
    @dbus.service.method("org.bluez.Profile1", in_signature="o", out_signature="")
    def RequestDisconnection(self, path): pass

class Agent(dbus.service.Object):
    """Pairing without input (NoInputNoOutput): confirm everything and trust the device"""
    def __init__(self, bus, path):
        super().__init__(bus, path); self.bus = bus
    def _trust(self, dev):
        try:
            dbus.Interface(self.bus.get_object("org.bluez", dev), "org.freedesktop.DBus.Properties").Set(
                "org.bluez.Device1", "Trusted", dbus.Boolean(True))
        except Exception as e:
            log("Trust failed:", e)
    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self): pass
    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def AuthorizeService(self, dev, uuid): self._trust(dev)
    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, dev): self._trust(dev)
    @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
    def RequestConfirmation(self, dev, passkey): log(f"Pairing confirmed ({passkey:06d})"); self._trust(dev)
    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
    def RequestPinCode(self, dev): return "0000"
    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
    def RequestPasskey(self, dev): return dbus.UInt32(0)
    @dbus.service.method("org.bluez.Agent1", in_signature="ouq", out_signature="")
    def DisplayPasskey(self, dev, passkey, entered): pass
    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Cancel(self): pass

def setup_bluez(desc):
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    Profile(bus, PROFILE_PATH)
    dbus.Interface(bus.get_object("org.bluez", "/org/bluez"), "org.bluez.ProfileManager1").RegisterProfile(
        PROFILE_PATH, PROFILE_UUID, {"ServiceRecord": sdp_record(desc), "Role": "server",
                                     "RequireAuthentication": False, "RequireAuthorization": False})
    Agent(bus, AGENT_PATH)
    am = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"), "org.bluez.AgentManager1")
    am.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
    am.RequestDefaultAgent(AGENT_PATH)
    props = dbus.Interface(bus.get_object("org.bluez", "/org/bluez/hci0"), "org.freedesktop.DBus.Properties")
    for k, v in (("Powered", True), ("Alias", NAME), ("Pairable", True), ("PairableTimeout", dbus.UInt32(0)),
                 ("DiscoverableTimeout", dbus.UInt32(0)), ("Discoverable", True)):
        try:
            props.Set("org.bluez.Adapter1", k, v if not isinstance(v, bool) else dbus.Boolean(v))
        except Exception as e:
            log(f"Adapter {k}: {e}")
    log("Bluetooth ready: visible as", repr(NAME))
    return bus

# ---------------------------------------------------------------- Bridge

class Bridge:
    def __init__(self):
        self.ctrl = self.intr = None
        self.lock = threading.Lock()
        self.host = None
        self.feature_mode = bytes([0x21, 0x02, 0x00])

    # --- connections
    def listen(self):
        def srv(psm):
            s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((socket.BDADDR_ANY, psm)); s.listen(1)
            return s
        self.sc, self.si = srv(PSM_CTRL), srv(PSM_INTR)
        threading.Thread(target=self._accept_loop, daemon=True).start()
        threading.Thread(target=self._reconnect_loop, daemon=True).start()

    def _accept_loop(self):
        while True:
            c, addr = self.sc.accept()
            log("Control channel connected:", addr[0])
            i, addr2 = self.si.accept()
            log("Interrupt channel connected:", addr2[0])
            self._set_connection(c, i, addr[0])

    def _set_connection(self, c, i, host):
        with self.lock:
            self._close_locked()
            self.ctrl, self.intr, self.host = c, i, host
            try:
                i.settimeout(1.0)   # sending must never block the touch reader thread for long
            except OSError:
                pass
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            json.dump({"host": host}, open(HOST_FILE, "w"))
        except OSError:
            pass
        threading.Thread(target=self._control_loop, args=(c,), daemon=True).start()

    def _close_locked(self):
        for s in (self.ctrl, self.intr):
            try:
                s and s.close()
            except OSError:
                pass
        self.ctrl = self.intr = None

    def disconnect(self, why):
        with self.lock:
            if self.ctrl:
                log("Connection closed:", why)
            self._close_locked()

    def _reconnect_loop(self):
        """Reconnects by itself to the last paired Mac (e.g. after the Pi reboots)"""
        while True:
            time.sleep(5)
            if self.ctrl:
                continue
            try:
                host = json.load(open(HOST_FILE))["host"]
            except Exception:
                continue
            try:
                c = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
                c.settimeout(5); c.connect((host, PSM_CTRL))
                i = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
                i.settimeout(5); i.connect((host, PSM_INTR))
                c.settimeout(None); i.settimeout(None)
                log("Reconnected to Mac:", host)
                self._set_connection(c, i, host)
            except OSError:
                time.sleep(10)

    # --- HID control channel (GET/SET_REPORT, SET_PROTOCOL, …)
    def _control_loop(self, c):
        while True:
            try:
                p = c.recv(64)
            except OSError:
                p = b""
            if not p:
                if c is self.ctrl:
                    self.disconnect("control channel closed")
                return
            t, param = p[0] >> 4, p[0] & 0x0F
            try:
                if t == 0x4:    # GET_REPORT
                    rtype, rid = param & 0x03, (p[1] if len(p) > 1 else 0)
                    if rtype == 3 and rid == 0x0A:
                        c.send(bytes([0xA3, 0x0A, 0x0A]))           # Contact Count Maximum: 10
                    elif rtype == 3 and rid == 0x21:
                        c.send(bytes([0xA3]) + self.feature_mode)
                    elif rtype == 1 and rid == 0x0D:
                        c.send(bytes([0xA1, 0x0D]) + bytes(52))
                    else:
                        c.send(bytes([0x02]))                         # HANDSHAKE ERR_INVALID_REPORT_ID
                elif t == 0x5:  # SET_REPORT
                    if param & 0x03 == 3 and len(p) >= 2 and p[1] == 0x21:
                        self.feature_mode = bytes(p[1:4]).ljust(3, b"\0")
                    c.send(bytes([0x00]))
                elif t in (0x6, 0x7, 0x9):  # GET_PROTOCOL/SET_PROTOCOL/SET_IDLE
                    c.send(bytes([0x00]) if t != 0x6 else bytes([0xA0, 0x01]))
                elif t == 0x8:  # GET_IDLE
                    c.send(bytes([0xA0, 0x00]))
                elif t == 0x1 and param == 0x5:  # HID_CONTROL VIRTUAL_CABLE_UNPLUG
                    self.disconnect("Mac unpaired")
                    try: os.remove(HOST_FILE)
                    except OSError: pass
                    return
            except OSError:
                pass

    def send_report(self, report: bytes):
        with self.lock:
            s = self.intr
        if not s:
            return
        try:
            s.send(b"\xA1" + report)
        except OSError as e:
            self.disconnect(f"send failed ({e})")

    # --- read the Anmite
    def touch_loop(self):
        last_missing = 0.0
        while True:
            path, _ = find_hidraw()
            if not path:
                if time.time() - last_missing > 60:
                    log("Anmite (touch) not found – connect the picture via HDMI and plug in the touch USB-C …")
                    last_missing = time.time()
                time.sleep(1)
                continue
            log("Reading touch reports from", path)
            try:
                fd = os.open(path, os.O_RDONLY)
            except OSError as e:
                log("Open failed:", e); time.sleep(2); continue
            n = 0
            burst, burst_start, last_rx = 0, 0.0, 0.0
            try:
                while True:
                    r, _, _ = select.select([fd], [], [], 5)
                    now = time.time()
                    if burst and now - last_rx > 2:
                        log(f"Touch: {burst} reports in {last_rx - burst_start:.1f} s"
                            + ("" if self.intr else " – no Mac connected, not sent"))
                        burst = 0
                    if not r:
                        continue
                    data = os.read(fd, 64)
                    if not data:
                        break
                    if data[0] == 0x0D:
                        if not burst:
                            burst_start = now
                        burst += 1
                        last_rx = now
                        self.send_report(data)
                        n += 1
                        if n == 1:
                            log("First multitouch report received" + (" – sending to the Mac" if self.intr else " (no Mac connected yet)"))
            except OSError as e:
                log("Anmite disconnected:", e.strerror)
            finally:
                os.close(fd)
            time.sleep(0.5)


def main():
    if os.geteuid() != 0:
        sys.exit("Please run as root (systemd service touchbridge-bt).")
    desc = load_descriptor()
    setup_bluez(desc)
    b = Bridge()
    b.listen()
    threading.Thread(target=b.touch_loop, daemon=True).start()
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
