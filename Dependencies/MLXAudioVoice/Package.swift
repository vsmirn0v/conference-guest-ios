// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "MLXAudioVoice", platforms: [.macOS(.v14)], products: [
    .library(name: "MLXAudioTTS", targets: ["MLXAudioTTS"]),
    .library(name: "MLXAudioCore", targets: ["MLXAudioCore"])
], dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.33.0"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.4.0"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.13.0")
], targets: [
    .target(name: "MLXAudioCore", dependencies: [
        .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"), .product(name: "HuggingFace", package: "swift-huggingface")
    ]),
    .target(name: "MLXAudioTTS", dependencies: ["MLXAudioCore", .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXRandom", package: "mlx-swift"), .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Transformers", package: "swift-transformers")], exclude: ["Models/VoxCPM2/README.md"])
])
