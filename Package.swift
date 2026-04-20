// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GazeSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "GazeProtocolKit", targets: ["GazeProtocolKit"]),
        .library(name: "GazeProviderKit", targets: ["GazeProviderKit"]),
    ],
    targets: [
        .target(
            name: "GazeProtocolKit",
            dependencies: []
        ),
        .target(
            name: "GazeProviderKit",
            dependencies: ["GazeProtocolKit"]
        ),
        .testTarget(
            name: "GazeProtocolKitTests",
            dependencies: ["GazeProtocolKit"]
        ),
    ]
)
