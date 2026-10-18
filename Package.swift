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
        // Plattformneutrale Logik: HID-Descriptor-Parser, Frames, Gesten, Mapping, DDC-Pakete
        .target(
            name: "TouchBridgeCore",
            path: "Sources/TouchBridgeCore",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // macOS-Anbindung: IOKit-HID-Dienst, Bildschirme, Bildsteuerung (DDC / Gamma), Rechte
        .target(
            name: "TouchBridgeKit",
            dependencies: ["TouchBridgeCore"],
            path: "Sources/TouchBridgeKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
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
