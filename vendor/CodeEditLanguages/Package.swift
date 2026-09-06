// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeEditLanguages",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CodeEditLanguages", targets: ["CodeEditLanguages"])],
    dependencies: [.package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", exact: "0.25.0")],
    targets: [
        .target(name: "CodeEditLanguages", dependencies: ["CodeLanguagesContainer", "SwiftTreeSitter"],
                resources: [.copy("Resources")], linkerSettings: [.linkedLibrary("c++")]),
        .binaryTarget(name: "CodeLanguagesContainer",
            url: "https://raw.githubusercontent.com/CodeEditApp/CodeEditLanguages/331d5dbc5fc8513be5848fce8a2a312908f36a11/CodeLanguagesContainer.xcframework.zip",
            checksum: "c6ee69d9d373a9c3cf93d239e05369d9b941275d31cd7956d0dc83b5a5c3e152"),
    ]
)
