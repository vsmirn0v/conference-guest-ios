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
            url: "https://github.com/vsmirn0v/conference-guest-ios/releases/download/guest-native-webrtc-150.7871.03-r3/WebRTC.xcframework.zip",
            checksum: "608473a0af243b899a7e201b5ed49fc2d0f35622ff089e4a74bfff9d30a78b7f"
        )
    ]
)
