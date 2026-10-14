// swift-tools-version: 5.9
import PackageDescription

// Required provider target names are confined to this integration package.
let package = Package(
    name: "GuestConferenceSDK",
    platforms: [.iOS(.v15)],
    products: [.library(name: "JazzSDK", targets: [
        "JazzSDK", "LibSberCast", "JazzCore", "WebRTC", "JazzScreenShareImpl", "SDSoup"
    ])],
    targets: [
        .binaryTarget(name: "JazzSDK", path: "VendorSources/JazzSDK.xcframework"),
        .binaryTarget(name: "LibSberCast", path: "VendorSources/LibSberCast.xcframework"),
        .binaryTarget(name: "JazzCore", path: "VendorSources/JazzCore.xcframework"),
        .binaryTarget(name: "JazzScreenShareImpl", path: "VendorSources/JazzScreenShareImpl.xcframework"),
        .binaryTarget(name: "SDSoup", path: "VendorSources/SDSoup.xcframework"),
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/vsmirn0v/conference-guest-ios/releases/download/guest-native-webrtc-150.7871.03-r6/WebRTC.xcframework.zip",
            checksum: "6d9655dad8e0ad9fb5a77e47a43e9064b5f6c6ee40c1eeaca53d1632cb0ef789"
        )
    ]
)
