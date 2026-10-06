// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenBeam",
    platforms: [.macOS("14.2")],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "ScreenBeam",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/ScreenBeam",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
