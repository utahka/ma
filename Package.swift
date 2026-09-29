// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ma",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Ma", path: "Sources/Ma")
    ]
)
