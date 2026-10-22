// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PortalMobile",
    platforms: [.iOS("26.1"), .macOS("15.0")],
    products: [.library(name: "PortalMobile", targets: ["PortalMobile"])],
    dependencies: [
        .package(path: "../shared/PortalDiscovery"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.14.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", revision: "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"),
    ],
    targets: [
        .target(name: "PortalMobileCore", dependencies: [.product(name: "PortalDiscovery", package: "PortalDiscovery"), .product(name: "Citadel", package: "Citadel")]),
        .target(name: "PortalMobile", dependencies: ["PortalMobileCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "PortalMobileCoreTests", dependencies: ["PortalMobileCore"]),
        .testTarget(name: "PortalMobileTests", dependencies: ["PortalMobile"]),
    ]
)
