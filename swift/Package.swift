// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DiscordAgentBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "DiscordAgentBridge",
            targets: ["DiscordAgentBridge"]
        ),
        .executable(
            name: "dab",
            targets: ["dab"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/DiscordBM/DiscordBM", from: "1.16.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1"),
    ],
    targets: [
        .target(
            name: "DiscordAgentBridge",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "dab",
            dependencies: [
                "DiscordAgentBridge",
                .product(name: "DiscordBM", package: "DiscordBM"),
            ]
        ),
        .testTarget(
            name: "DiscordAgentBridgeTests",
            dependencies: ["DiscordAgentBridge"]
        ),
    ]
)
