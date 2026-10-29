// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeAccounts",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeAccounts",
            path: "Sources/ClaudeAccounts",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
