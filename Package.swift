// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glimpse",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Glimpse",
            path: "Sources/Glimpse",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "GlimpseTests",
            dependencies: ["Glimpse"],
            path: "Tests/GlimpseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
