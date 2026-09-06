// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "git-sync",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GitSyncCore", targets: ["GitSyncCore"]),
        .executable(name: "gitinuum", targets: ["gitinuum"]),
        .executable(name: "gitinuumd", targets: ["gitinuumd"]),
        .executable(name: "GitinuumApp", targets: ["GitSyncApp"]),
        .executable(name: "GitSyncMenuBar", targets: ["GitSyncMenuBar"]),
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
        .target(name: "GitSyncCore", dependencies: ["GitSyncWatch"]),
        .target(name: "GitSyncEngine", dependencies: ["GitSyncCore"]),
        .target(name: "GitSyncGraph", dependencies: ["GitSyncCore"]),
        .executableTarget(name: "gitinuum"),
        .executableTarget(name: "gitinuumd", dependencies: ["GitSyncCore"]),
        .executableTarget(
            name: "GitSyncApp",
            dependencies: ["GitSyncCore", "GitSyncEngine", "GitSyncGraph", .product(name: "gitdiff", package: "gitdiff"),
                           .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor", condition: .when(platforms: [.macOS])),
                           .product(name: "Textual", package: "textual", condition: .when(platforms: [.macOS]))]
        ),
        .executableTarget(name: "GitSyncMenuBar", dependencies: ["GitSyncEngine"]),
        .testTarget(name: "GitinuumCLITests", dependencies: ["gitinuum"]),
        .testTarget(name: "GitSyncTests", dependencies: ["GitSyncCore"]),
        .testTarget(name: "GitSyncGraphTests", dependencies: ["GitSyncGraph", "GitSyncCore"]),
        .testTarget(name: "GitSyncEngineTests", dependencies: ["GitSyncEngine"]),
        .testTarget(name: "GitSyncAppTests", dependencies: ["GitSyncApp"]),
    ]
)
