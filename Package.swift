// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "git-sync",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GitSyncCore", targets: ["GitSyncCore"]),
        .executable(name: "git-sync", targets: ["git-sync"]),
        .executable(name: "GitSync", targets: ["GitSyncApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tornikegomareli/gitdiff.git", exact: "0.1.0"),
    ],
    targets: [
        .target(
            name: "GitSyncWatch",
            linkerSettings: [.linkedFramework("CoreServices", .when(platforms: [.macOS]))]
        ),
        .target(name: "GitSyncCore", dependencies: ["GitSyncWatch"]),
        .target(name: "GitSyncGraph", dependencies: ["GitSyncCore"]),
        .executableTarget(name: "git-sync", dependencies: ["GitSyncCore"]),
        .executableTarget(
            name: "GitSyncApp",
            dependencies: ["GitSyncCore", "GitSyncGraph", .product(name: "gitdiff", package: "gitdiff")]
        ),
        .testTarget(name: "GitSyncTests", dependencies: ["GitSyncCore"]),
        .testTarget(name: "GitSyncGraphTests", dependencies: ["GitSyncGraph", "GitSyncCore"]),
        .testTarget(name: "GitSyncAppTests", dependencies: ["GitSyncApp"]),
    ]
)
