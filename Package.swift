// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "portal",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PortalCore", targets: ["PortalCore"]),
        .executable(name: "portal", targets: ["portal"]),
        .executable(name: "portald", targets: ["portald"]),
        .executable(name: "PortalApp", targets: ["PortalApp"]),
        .executable(name: "PortalTerminalApp", targets: ["PortalTerminalApp"]),
        .executable(name: "PortalMenuBar", targets: ["PortalMenuBar"]),
    ],
    dependencies: [
        .package(path: "vendor/gitdiff"),
        .package(path: "shared/PortalDiscovery"),
        .package(url: "https://github.com/gonzalezreal/textual.git", exact: "0.5.0"),
        .package(path: "vendor/CodeEditSourceEditor"),
    ],
    targets: [
        .target(
            name: "PortalWatch",
            linkerSettings: [.linkedFramework("CoreServices", .when(platforms: [.macOS]))]
        ),
        .target(name: "PortalTerminal", dependencies: ["PortalCore"], exclude: ["PROVENANCE.md"], resources: [.copy("Resources/completions")]),
        .target(name: "PortalCore", dependencies: ["PortalWatch"]),
        .target(name: "PortalEngine", dependencies: ["PortalCore"]),
        .target(name: "PortalGraph", dependencies: ["PortalCore"]),
        .executableTarget(name: "portal"),
        .executableTarget(name: "portald", dependencies: ["PortalCore"]),
        .executableTarget(
            name: "PortalApp",
            dependencies: [.product(name: "PortalDiscovery", package: "PortalDiscovery", condition: .when(platforms: [.macOS])), .target(name: "PortalTerminal", condition: .when(platforms: [.macOS])), "PortalCore", "PortalEngine", "PortalGraph", .product(name: "gitdiff", package: "gitdiff"),
                           .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor", condition: .when(platforms: [.macOS])),
                           .product(name: "Textual", package: "textual", condition: .when(platforms: [.macOS]))],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "PortalTerminalApp", dependencies: ["PortalTerminal", "PortalEngine"]),
        .executableTarget(name: "PortalMenuBar", dependencies: ["PortalEngine"]),
        .testTarget(name: "PortalTerminalTests", dependencies: ["PortalTerminal", "PortalTerminalApp"]),
        .testTarget(name: "PortalCLITests", dependencies: ["portal"]),
        .testTarget(name: "PortalTests", dependencies: ["PortalCore"]),
        .testTarget(name: "PortalGraphTests", dependencies: ["PortalGraph", "PortalCore"]),
        .testTarget(name: "PortalEngineTests", dependencies: ["PortalEngine"]),
        .testTarget(name: "PortalAppTests", dependencies: ["PortalApp"]),
    ]
)
