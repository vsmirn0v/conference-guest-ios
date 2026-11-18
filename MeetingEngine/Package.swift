// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingEngine",
    platforms: [
        .iOS("16.0"),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MeetingEngine",
            targets: ["MeetingEngine"]
        ),
    ],
    dependencies: [
        .package(path: "../ConferenceCore"),
        .package(path: "../.build/unified-sdk-dependencies/client-sdk-swift"),
        .package(path: "../.build/unified-sdk-dependencies/webrtc-xcframework"),
    ],
    targets: [
        .target(
            name: "MeetingEngine",
            dependencies: [
                .product(name: "ConferenceCore", package: "ConferenceCore"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ]
        ),
        .testTarget(
            name: "MeetingEngineTests",
            dependencies: ["MeetingEngine"]
        ),
    ]
)
