// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ma",
    platforms: [.macOS(.v15)],
    dependencies: [
        // `.base`（Obsidian の Bases）の YAML を読む
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .executableTarget(name: "Ma", dependencies: ["Yams"], path: "Sources/Ma"),
        .testTarget(name: "MaTests", dependencies: ["Ma"], path: "Tests",
                    exclude: ["AICommentSelectionTests.swift", "TableRowMoveTests.swift"],
                    sources: ["TabTransferTests.swift", "AICommentStylingTests.swift"])
    ]
)
