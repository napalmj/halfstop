// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pixon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pixon",
            path: "Sources/Pixon",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ],
    swiftLanguageModes: [.v5]
)
