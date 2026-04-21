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
        .library(name: "GazeCoreKit", targets: ["GazeCoreKit"]),
    ],
    targets: [
        .target(
            name: "GazeCoreC",
            dependencies: [],
            path: "core",
            publicHeadersPath: "include"
        ),
        .target(
            name: "GazeProtocolKit",
            dependencies: []
        ),
        .target(
            name: "GazeCoreKit",
            dependencies: ["GazeCoreC", "GazeProtocolKit"]
        ),
        .target(
            name: "GazeProviderKit",
            dependencies: ["GazeProtocolKit"]
        ),
        .testTarget(
            name: "GazeProtocolKitTests",
            dependencies: ["GazeProtocolKit", "GazeCoreKit"],
            path: "tests/GazeProtocolKitTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
