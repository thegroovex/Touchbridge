import AppKit

// TouchBridge – Menüleisten-App

// Nur eine Instanz: eine ältere (z. B. nach einem Update) wird beendet, damit sie das Touch-Gerät
// und den DDC-Zugang freigibt – zwei Instanzen würden sich den exklusiven Zugriff streitig machen.
if let bid = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    for o in others { o.terminate() }
    let deadline = Date().addingTimeInterval(3)
    while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    for o in others where !o.isTerminated { o.forceTerminate() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
