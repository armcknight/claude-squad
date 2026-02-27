// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSquad",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Library target containing all logic – importable by both the executable and tests.
        .target(
            name: "ClaudeSquadLib",
            path: "Sources/ClaudeSquadLib"
        ),
        // Thin executable wrapper – only contains main.swift.
        .executableTarget(
            name: "ClaudeSquad",
            dependencies: ["ClaudeSquadLib"],
            path: "Sources/ClaudeSquad"
        ),
        .testTarget(
            name: "ClaudeSquadTests",
            dependencies: ["ClaudeSquadLib"],
            path: "Tests/ClaudeSquadTests"
        )
    ]
)
