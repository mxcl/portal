// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaulttySwiftDependencies",
    platforms: [
        .macOS(.v12),
        .iOS("26.1"),
    ],
    products: [
        .library(name: "VaulttySwiftDependencies", targets: ["VaulttySwiftDependencies"]),
        .library(name: "VaulttyCore", targets: ["VaulttyCore"]),
        .library(name: "VaulttyMobile", targets: ["VaulttyMobile"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "2.1.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.14.0"),
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
        .target(
            name: "VaulttyMobile",
            dependencies: [
                "VaulttyCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "src/ios"
        ),
        .testTarget(
            name: "VaulttyCoreTests",
            dependencies: ["VaulttyCore"]
        ),
    ]
)
