// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsiriXBackupPlugin",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "OsiriXBackupPlugin",
            targets: ["OsiriXBackupPlugin"]
        )
    ],
    targets: [
        .target(
            name: "OsiriXBackupPlugin",
            path: "Sources/Swift",
            exclude: [
                "Advanced",
                "Core/OsiriXBackup.swift",
                "Core/Plugin.swift",
                "Core/OsiriXAPI+Wrappers.swift",
                "OsiriXBackupController.swift"
            ],
            sources: [
                "Core/OsiriXBackupCore.swift"
            ]
        ),
        .testTarget(
            name: "OsiriXBackupPluginTests",
            dependencies: ["OsiriXBackupPlugin"],
            path: "Tests/OsiriXBackupPluginTests"
        )
    ]
)
