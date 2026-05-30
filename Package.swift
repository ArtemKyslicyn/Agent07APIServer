// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Agent07APIServer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Agent07APIServer", targets: ["Agent07APIServer"])
    ],
    targets: [
        .target(name: "Agent07APIServer"),
        .testTarget(
            name: "Agent07APIServerTests",
            dependencies: ["Agent07APIServer"]
        )
    ],
    swiftLanguageModes: [.v6]
)
