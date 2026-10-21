import AppKit

/// Menu-bar (accessory) apps are often not activated on macOS 14+, so a plain
/// makeKeyAndOrderFront leaves the window hidden behind other apps. Force it to the front.
enum WindowFront {
    static func bring(_ w: NSWindow) {
        w.collectionBehavior.insert(.moveToActiveSpace)
        if w.isMiniaturized { w.deminiaturize(nil) }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        // Back to normal level shortly after, so it does not stay above everything
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak w] in
            guard let w = w else { return }
            w.level = .normal
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
        NSLog("TouchBridge: window '%@' shown at %@ (visible=%d)", w.title, NSStringFromRect(w.frame), w.isVisible ? 1 : 0)
    }
}
