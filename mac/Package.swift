// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenBeam",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "ScreenBeam",
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
