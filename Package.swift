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
                "https://github.com/mattt/lore-swift/releases/download/liblore-0.14.0/liblore.xcframework.zip",
            checksum: "2c677d9f68eb9d423afb3f967976b8a84d86ebf5ea1f0b3f22f3a006e83a2e9a"
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
