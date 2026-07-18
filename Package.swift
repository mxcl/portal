// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaulttySwiftDependencies",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "VaulttySwiftDependencies", targets: ["VaulttySwiftDependencies"]),
        .library(name: "VaulttyCore", targets: ["VaulttyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "2.1.1"),
    ],
    targets: [
        .target(
            name: "VaulttySwiftDependencies",
            dependencies: [
                .product(name: "AppUpdater", package: "AppUpdater"),
            ]
        ),
        .target(
            name: "VaulttyCore",
            path: "src/core"
        ),
        .testTarget(
            name: "VaulttyCoreTests",
            dependencies: ["VaulttyCore"]
        ),
    ]
)
