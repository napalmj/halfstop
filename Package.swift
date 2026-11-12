// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Halfstop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Halfstop",
            path: "Sources/Halfstop"
            // Release builds use plain -O: bounds and overflow checks stay on, so a bug driven by
            // file data stops with a crash instead of corrupting memory.
        )
    ],
    swiftLanguageModes: [.v5]
)
