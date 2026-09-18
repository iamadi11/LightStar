// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LightStarCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "LightStarCore", targets: ["LightStarCore"])
    ],
    targets: [
        .target(name: "LightStarCore"),
        .testTarget(
            name: "LightStarCoreTests",
            dependencies: ["LightStarCore"]
        )
    ]
)
