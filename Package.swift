// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TouchBridge",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "TouchBridge", targets: ["TouchBridge"]),
    ],
    targets: [
        // Plattformneutrale Logik: HID-Descriptor-Parser, Frame-Zusammenbau, Gesten-Engine
        .target(
            name: "TouchBridgeCore",
            path: "Sources/TouchBridgeCore",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // CLI: IOKit-HID-Anbindung, Bildschirm-Mapping, Rechte
        .executableTarget(
            name: "TouchBridge",
            dependencies: ["TouchBridgeCore"],
            path: "Sources/TouchBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "TouchBridgeCoreTests",
            dependencies: ["TouchBridgeCore"],
            path: "Tests/TouchBridgeCoreTests"
        ),
    ]
)
