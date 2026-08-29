// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "git-sync",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GitSyncCore", targets: ["GitSyncCore"]),
        .executable(name: "git-sync", targets: ["git-sync"]),
        .executable(name: "GitSync", targets: ["GitSyncApp"]),
    ],
    targets: [
        .target(
            name: "GitSyncWatch",
            linkerSettings: [.linkedFramework("CoreServices", .when(platforms: [.macOS]))]
        ),
        .target(name: "GitSyncCore", dependencies: ["GitSyncWatch"]),
        .executableTarget(name: "git-sync", dependencies: ["GitSyncCore"]),
        .executableTarget(name: "GitSyncApp", dependencies: ["GitSyncCore"]),
        .testTarget(name: "GitSyncTests", dependencies: ["GitSyncCore"]),
    ]
)
