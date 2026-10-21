import Darwin
import Foundation
import IOKit
import TouchBridgeCore

/// Serial link to the nRF52840 digitizer dongle (firmware/nrf-digitizer): finds the CDC ACM port by
/// USB VID/PID (2fe3:0010), opens it raw (termios), sends HELLO and TOUCH frames, reconnects every 2 s.
/// All I/O runs on a private serial queue; `send` may be called from any thread.
public final class NRFDigitizerBridge {
    public struct Status: Equatable {
        public var active = false
        public var connected = false
        public var path: String?
        public var hello: DigitizerHello?
        public var lastError: String?

        /// One menu line, e.g. "Digitizer dongle: connected (firmware 0.1.0, s140v6)"
        public var summary: String {
            if !active { return L("Digitizer dongle: off", "Digitizer-Dongle: aus") }
            guard connected else { return L("Digitizer dongle: not connected", "Digitizer-Dongle: nicht verbunden") }
            if let h = hello {
                return L("Digitizer dongle: connected (firmware \(h.version), \(h.variantName))",
                         "Digitizer-Dongle: verbunden (Firmware \(h.version), \(h.variantName))")
            }
            return L("Digitizer dongle: port open, waiting for answer", "Digitizer-Dongle: Port offen, wartet auf Antwort")
        }
    }

    public var log: (String) -> Void = { print($0) }
    /// Called on the main queue whenever the status changes
    public var onStatus: ((Status) -> Void)?

    private let queue = DispatchQueue(label: "touchbridge.nrf-digitizer")
    // state below: queue only
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var parser = DigitizerFrameParser()
    private var latest: [DigitizerContact] = []
    private var latestDirty = false
    private var lastSent = 0.0
    private var lastHello = 0.0
    private var flushScheduled = false
    private var lastMissingLog = 0.0
    /// frames written since start (diagnostics; queue only)
    private var framesSent = 0
    private var state = Status() {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { [weak self] in
                self?.mainStatus = s
                self?.onStatus?(s)
            }
        }
    }
    /// Last status, readable on the main thread
    public private(set) var mainStatus = Status()

    public init() {}
    deinit {
        timer?.cancel()
        readSource?.cancel()
    }

    // MARK: lifecycle

    public func start() {
        queue.async {
            guard !self.state.active else { return }
            self.state.active = true
            self.log("🔌 Digitizer output on – looking for \(NRFDigitizer.productName) (USB \(String(format: "%04x:%04x", NRFDigitizer.vendorID, NRFDigitizer.productID)))")
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: NRFDigitizer.keepAliveInterval / 2)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.async {
            guard self.state.active else { return }
            if self.fd >= 0 { self.write(NRFDigitizer.releaseAllFrame()) }
            self.timer?.cancel(); self.timer = nil
            self.close(reason: nil)
            self.latest = []
            self.state = Status()
            self.log("🔌 Digitizer output off")
        }
    }

    /// Current contacts (tip down). An empty list lifts every finger.
    public func send(_ contacts: [DigitizerContact]) {
        queue.async {
            guard self.state.active else { return }
            if contacts.isEmpty && self.latest.isEmpty && !self.latestDirty { return }
            self.latest = contacts
            self.latestDirty = true
            self.flush()
        }
    }

    /// Restart the dongle into its UF2 bootloader (firmware update); the drive appears on the Mac.
    public func enterBootloader() {
        queue.async {
            guard self.fd >= 0 else { self.log("⚠️  Digitizer dongle not connected – cannot start the bootloader"); return }
            self.write(NRFDigitizer.bootloaderFrame())
            self.log("🔌 Digitizer dongle: restarting into the UF2 bootloader")
        }
    }

    // MARK: sending

    private func flush() {
        guard fd >= 0, latestDirty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let minGap = 1.0 / NRFDigitizer.maxRate
        if now - lastSent < minGap {
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + (minGap - (now - lastSent))) { [weak self] in
                self?.flushScheduled = false
                self?.flush()
            }
            return
        }
        sendLatest(now)
    }

    private func sendLatest(_ now: Double) {
        latestDirty = false
        lastSent = now
        if write(NRFDigitizer.touchFrame(latest)) { framesSent += 1 }
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        if fd < 0 {
            if now - lastHello >= 2 { lastHello = now; connect() }
            return
        }
        // keep-alive: the dongle lifts all contacts after 200 ms without a frame
        if !latest.isEmpty && now - lastSent >= NRFDigitizer.keepAliveInterval { sendLatest(now) }
        if state.hello == nil && now - lastHello >= 2 {
            lastHello = now
            write(NRFDigitizer.helloFrame())
        }
        // port gone (unplugged) without a read error?
        if let p = state.path, access(p, F_OK) != 0 { close(reason: "unplugged") }
    }

    @discardableResult
    private func write(_ bytes: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if n == bytes.count { return true }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return false } // full: drop this frame
        close(reason: n < 0 ? String(cString: strerror(errno)) : "short write")
        return false
    }

    // MARK: port

    private func connect() {
        guard let path = Self.findPort() else {
            if state.connected || state.lastError == nil || CFAbsoluteTimeGetCurrent() - lastMissingLog > 60 {
                lastMissingLog = CFAbsoluteTimeGetCurrent()
                log("🔌 Digitizer dongle not found (USB \(String(format: "%04x:%04x", NRFDigitizer.vendorID, NRFDigitizer.productID))) – plug it in; TouchBridge sends no events meanwhile")
            }
            state.lastError = "not found"
            return
        }
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else {
            let e = String(cString: strerror(errno))
            if state.lastError != e { log("❌ Digitizer dongle \(path): open failed (\(e))") }
            state.lastError = e
            return
        }
        _ = ioctl(f, Self.TIOCEXCL)
        var t = termios()
        if tcgetattr(f, &t) == 0 {
            cfmakeraw(&t)
            t.c_cflag |= tcflag_t(CLOCAL | CREAD | HUPCL)
            cfsetspeed(&t, speed_t(B115200))
            _ = tcsetattr(f, TCSANOW, &t)
        }
        _ = ioctl(f, Self.TIOCSDTR) // DTR on: the dongle treats the port as open
        tcflush(f, TCIOFLUSH)
        fd = f
        parser.reset()
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume()
        readSource = src
        state.connected = true
        state.path = path
        state.hello = nil
        state.lastError = nil
        log("🔌 Digitizer dongle connected: \(path)")
        lastHello = CFAbsoluteTimeGetCurrent()
        write(NRFDigitizer.helloFrame())
        if !latest.isEmpty { latestDirty = true; flush() }
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            close(reason: n == 0 ? "closed" : String(cString: strerror(errno)))
            return
        }
        guard n > 0 else { return }
        for payload in parser.feed(buf[0..<n]) {
            guard let type = payload.first.flatMap(NRFDigitizer.MessageType.init(rawValue:)) else { continue }
            switch type {
            case .helloReply:
                if let h = DigitizerHello(payload: payload) {
                    if state.hello == nil {
                        log("🔌 Digitizer dongle: firmware \(h.version) (\(h.variantName), protocol \(h.protocolVersion), \(h.maxContacts) contacts)")
                        if h.protocolVersion != NRFDigitizer.protocolVersion {
                            log("⚠️  Digitizer dongle speaks protocol \(h.protocolVersion), TouchBridge \(NRFDigitizer.protocolVersion) – update the firmware")
                        }
                    }
                    state.hello = h
                }
            case .error:
                log("⚠️  Digitizer dongle rejected a frame (code \(payload.count > 1 ? Int(payload[1]) : 0))")
            default:
                break
            }
        }
    }

    private func close(reason: String?) {
        readSource?.cancel(); readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
            if let r = reason { log("🔌 Digitizer dongle disconnected (\(r)) – reconnecting every 2 s") }
        }
        if state.active {
            state.connected = false
            state.hello = nil
            state.path = nil
            if let r = reason { state.lastError = r }
        }
    }

    // _IO('t', 13) / _IO('t', 121) – the macros are not imported into Swift
    private static let TIOCEXCL: UInt = 0x2000_740D
    private static let TIOCSDTR: UInt = 0x2000_7479

    /// /dev/cu.* of the first serial port whose USB device has the dongle's VID/PID
    public static func findPort(vendorID: Int = NRFDigitizer.vendorID, productID: Int = NRFDigitizer.productID) -> String? {
        guard let match = IOServiceMatching("IOSerialBSDClient") else { return nil }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var found: String?
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard found == nil else { continue }
            let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            func number(_ key: String) -> Int? {
                IORegistryEntrySearchCFProperty(svc, kIOServicePlane, key as CFString, kCFAllocatorDefault, opts) as? Int
            }
            guard number("idVendor") == vendorID, number("idProduct") == productID,
                  let path = IORegistryEntryCreateCFProperty(svc, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            found = path
        }
        return found
    }
}
