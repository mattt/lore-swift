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
            url:
                "https://github.com/mattt/lore-swift/releases/download/liblore-0.13.0/liblore.xcframework.zip",
            checksum: "6105ab7023b2c6f841d7d8cf0f01fa6c88310fdeef324bae96eeacab159b870d"
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
