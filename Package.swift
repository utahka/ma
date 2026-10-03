// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Awai",
    platforms: [.macOS(.v15)],
    dependencies: [
        // `.base`（Obsidian の Bases）の YAML を読む
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .executableTarget(name: "Awai", dependencies: ["Yams"], path: "Sources/Awai"),
        .testTarget(name: "AwaiTests", dependencies: ["Awai"], path: "Tests",
                    exclude: ["AICommentSelectionTests.swift", "TableRowMoveTests.swift"],
                    sources: ["TabTransferTests.swift", "AICommentStylingTests.swift", "WikiLinkCompletionTests.swift", "NoteRenameTests.swift"])
    ]
)
