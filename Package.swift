// swift-tools-version: 6.0
// Bardic — local AI voice dictation for macOS.
//
// Versions are pinned to releases that build with Xcode 16.3 / Swift 6.1.
// Newer mlx-swift (>= 0.31.5) and mlx-swift-lm (>= 3.32) require Swift 6.2+.

import PackageDescription

let package = Package(
    name: "Bardic",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bardic", targets: ["Bardic"]),
        .executable(name: "bardic-cli", targets: ["BardicCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"),
    ],
    targets: [
        .target(
            name: "BardicCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]
        ),
        .executableTarget(
            name: "Bardic",
            dependencies: ["BardicCore"]
        ),
        .executableTarget(
            name: "BardicCLI",
            dependencies: ["BardicCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
