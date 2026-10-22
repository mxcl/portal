// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PortalDiscovery", platforms: [.macOS("15.0"), .iOS("26.1")],
    products: [.library(name: "PortalDiscovery", targets: ["PortalDiscovery"])],
    targets: [.target(name: "PortalDiscovery"), .testTarget(name: "PortalDiscoveryTests", dependencies: ["PortalDiscovery"])])
