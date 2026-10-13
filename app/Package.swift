// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tact",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tact",
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
