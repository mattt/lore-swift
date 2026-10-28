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
                "https://github.com/mattt/lore-swift/releases/download/liblore-0.11.0/liblore.xcframework.zip",
            checksum: "6b5ac230083fb204cefb56af05f2cf1fefe05e5327a40c422a673acc94aea3e8"
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
