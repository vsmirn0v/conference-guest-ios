// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConferenceCore",
    defaultLocalization: "en",
    platforms: [.iOS("16.0"), .macOS(.v13)],
    products: [
        .library(name: "ConferenceCore", targets: ["ConferenceCore"])
    ],
    targets: [
        .target(name: "ConferenceCore", resources: [.process("Resources")]),
        .testTarget(name: "ConferenceCoreTests", dependencies: ["ConferenceCore"])
    ]
)
