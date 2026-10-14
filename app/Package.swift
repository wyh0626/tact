// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tact",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tact",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Tact",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
            ]
        ),
        .testTarget(
            name: "TactTests",
            dependencies: ["Tact"],
            path: "Tests/TactTests"
        ),
    ]
)
