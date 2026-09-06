// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeScroll",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "VibeScrollCore",
            path: "Sources/VibeScrollCore"
        ),
        .executableTarget(
            name: "vibescroll",
            dependencies: ["VibeScrollCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "VibeScrollCoreTests",
            dependencies: ["VibeScrollCore"],
            path: "Tests/VibeScrollCoreTests"
        ),
    ]
)
