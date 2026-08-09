// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortalSwiftDependencies",
    platforms: [
        .macOS(.v12),
        .iOS("26.1"),
    ],
    products: [
        .library(name: "PortalSwiftDependencies", targets: ["PortalSwiftDependencies"]),
        .library(name: "PortalCore", targets: ["PortalCore"]),
        .library(name: "PortalMobile", targets: ["PortalMobile"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "2.1.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.14.0"),
    ],
    targets: [
        .target(
            name: "PortalSwiftDependencies",
            dependencies: [
                .product(name: "AppUpdater", package: "AppUpdater"),
            ]
        ),
        .target(
            name: "PortalCore",
            path: "src/core"
        ),
        .target(
            name: "PortalMobile",
            dependencies: [
                "PortalCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "src/ios"
        ),
        .testTarget(
            name: "PortalCoreTests",
            dependencies: ["PortalCore"]
        ),
        .testTarget(
            name: "PortalMobileTests",
            dependencies: ["PortalMobile"]
        ),
    ]
)
