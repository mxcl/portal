// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeEditSourceEditor",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CodeEditSourceEditor", targets: ["CodeEditSourceEditor"])],
    dependencies: [
        .package(path: "../CodeEditTextView"),
        .package(path: "../CodeEditLanguages"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", exact: "0.9.0"),
    ],
    targets: [.target(name: "CodeEditSourceEditor", dependencies: [
        "CodeEditTextView", "CodeEditLanguages", "TextFormation"
    ])]
)
