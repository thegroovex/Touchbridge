// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TouchBridge",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "TouchBridge", targets: ["TouchBridge"]),
        .executable(name: "TouchBridgeApp", targets: ["TouchBridgeApp"]),
    ],
    targets: [
        // Plattformneutrale Logik: HID-Descriptor-Parser, Frames, Gesten, Mapping, DDC-Pakete, MIDI/MPE-Engine
        .target(
            name: "TouchBridgeCore",
            path: "Sources/TouchBridgeCore",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Carbon")]
        ),
        // Direkte USB-Control-Requests (IOUSBLib, C) für die Multitouch-Experimente
        .target(
            name: "TouchBridgeUSB",
            path: "Sources/TouchBridgeUSB",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        // macOS-Anbindung: IOKit-HID-Dienst, Bildschirme, Bildsteuerung (DDC / Gamma), CoreMIDI-Port, Rechte
        .target(
            name: "TouchBridgeKit",
            dependencies: ["TouchBridgeCore", "TouchBridgeUSB"],
            path: "Sources/TouchBridgeKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
            ]
        ),
        // Kommandozeile (touchbridge)
        .executableTarget(
            name: "TouchBridge",
            dependencies: ["TouchBridgeKit"],
            path: "Sources/TouchBridge"
        ),
        // Menüleisten-App (TouchBridge.app)
        .executableTarget(
            name: "TouchBridgeApp",
            dependencies: ["TouchBridgeKit"],
            path: "Sources/TouchBridgeApp",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(
            name: "TouchBridgeCoreTests",
            dependencies: ["TouchBridgeCore"],
            path: "Tests/TouchBridgeCoreTests"
        ),
    ]
)
