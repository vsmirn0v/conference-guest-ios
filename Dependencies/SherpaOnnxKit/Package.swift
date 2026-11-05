// swift-tools-version:5.9
// Local speech runtime for Rock'N'Roll for Mac. Run NativeMacGuest/prepare-sherpa.py
// first: it builds Artifacts/CSherpaOnnx.xcframework from the pinned sherpa-onnx release.
import PackageDescription

let package = Package(
    name: "SherpaOnnxKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SherpaOnnxKit", targets: ["SherpaOnnxKit"])],
    targets: [
        .binaryTarget(name: "CSherpaOnnx", path: "Artifacts/CSherpaOnnx.xcframework"),
        .target(name: "SherpaOnnxKit", dependencies: ["CSherpaOnnx"],
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Foundation")]),
        .testTarget(name: "SherpaOnnxKitTests", dependencies: ["SherpaOnnxKit"]),
    ]
)
