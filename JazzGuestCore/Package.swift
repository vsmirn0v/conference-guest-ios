// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JazzGuestCore",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [
        .library(name: "JazzGuestCore", targets: ["JazzGuestCore"])
    ],
    targets: [
        .target(name: "JazzGuestCore"),
        .testTarget(name: "JazzGuestCoreTests", dependencies: ["JazzGuestCore"])
    ]
)
