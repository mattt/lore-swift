// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "lore-swift",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Lore", targets: ["Lore"])
    ],
    targets: [
        .binaryTarget(
            name: "liblore",
            path: "Vendor/liblore.xcframework"
        ),
        .target(
            name: "CLore",
            dependencies: ["liblore"]
        ),
        .target(
            name: "Lore",
            dependencies: ["CLore"]
        ),
        .testTarget(
            name: "LoreTests",
            dependencies: ["Lore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
