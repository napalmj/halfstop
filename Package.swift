// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Halfstop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Halfstop",
            path: "Sources/Halfstop",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ],
    swiftLanguageModes: [.v5]
)
