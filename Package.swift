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
                "https://github.com/mattt/lore-swift/releases/download/liblore-0.12.0/liblore.xcframework.zip",
            checksum: "1e2d9536e6e78c1634258162ab8764e41a8cca7aed72601056c7ae5f2e725fb6"
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
