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
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.7.0")
    ],
    targets: [
        .target(
            name: "LightStarCore",
            dependencies: ["BigInt"],
            resources: [
                .process("MetalColorAnalyzer.metal")
            ]
        ),
        .testTarget(
            name: "LightStarCoreTests",
            dependencies: ["LightStarCore"]
        )
    ]
)
