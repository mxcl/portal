// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "git-sync",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GitSyncCore", targets: ["GitSyncCore"]),
        .executable(name: "portal", targets: ["portal"]),
        .executable(name: "portald", targets: ["portald"]),
        .executable(name: "PortalApp", targets: ["GitSyncApp"]),
        .executable(name: "PortalTerminalApp", targets: ["PortalTerminalApp"]),
        .executable(name: "PortalMenuBar", targets: ["GitSyncMenuBar"]),
    ],
    dependencies: [
        .package(path: "vendor/gitdiff"),
        .package(url: "https://github.com/gonzalezreal/textual.git", exact: "0.5.0"),
        .package(path: "vendor/CodeEditSourceEditor"),
    ],
    targets: [
        .target(
            name: "GitSyncWatch",
            linkerSettings: [.linkedFramework("CoreServices", .when(platforms: [.macOS]))]
        ),
        .target(name: "PortalTerminal", dependencies: ["GitSyncCore"], exclude: ["PROVENANCE.md"], resources: [.copy("Resources/completions")]),
        .target(name: "GitSyncCore", dependencies: ["GitSyncWatch"]),
        .target(name: "GitSyncEngine", dependencies: ["GitSyncCore"]),
        .target(name: "GitSyncGraph", dependencies: ["GitSyncCore"]),
        .executableTarget(name: "portal"),
        .executableTarget(name: "portald", dependencies: ["GitSyncCore"]),
        .executableTarget(
            name: "GitSyncApp",
            dependencies: [.target(name: "PortalTerminal", condition: .when(platforms: [.macOS])), "GitSyncCore", "GitSyncEngine", "GitSyncGraph", .product(name: "gitdiff", package: "gitdiff"),
                           .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor", condition: .when(platforms: [.macOS])),
                           .product(name: "Textual", package: "textual", condition: .when(platforms: [.macOS]))],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "PortalTerminalApp", dependencies: ["PortalTerminal", "GitSyncEngine"]),
        .executableTarget(name: "GitSyncMenuBar", dependencies: ["GitSyncEngine"]),
        .testTarget(name: "PortalTerminalTests", dependencies: ["PortalTerminal"]),
        .testTarget(name: "PortalCLITests", dependencies: ["portal"]),
        .testTarget(name: "GitSyncTests", dependencies: ["GitSyncCore"]),
        .testTarget(name: "GitSyncGraphTests", dependencies: ["GitSyncGraph", "GitSyncCore"]),
        .testTarget(name: "GitSyncEngineTests", dependencies: ["GitSyncEngine"]),
        .testTarget(name: "GitSyncAppTests", dependencies: ["GitSyncApp"]),
    ]
)
