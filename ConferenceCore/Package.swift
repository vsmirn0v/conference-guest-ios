// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConferenceCore",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [
        .library(name: "ConferenceCore", targets: ["ConferenceCore"])
    ],
    targets: [
        .target(name: "ConferenceCore"),
        .testTarget(name: "ConferenceCoreTests", dependencies: ["ConferenceCore"])
    ]
)
