// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveKitWebRTC",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [.library(name: "LiveKitWebRTC", targets: ["LiveKitWebRTC"])],
    targets: [
        .binaryTarget(
            name: "LiveKitWebRTC",
            url: "https://github.com/vsmirn0v/conference-guest-ios/releases/download/native-webrtc-150.7871.03-r3/LiveKitWebRTC.xcframework.zip",
            checksum: "5f008d7f913fe4fa8255637499dede73a016571e9d64b86c59c6f9e9bcb61dbc"
        )
    ]
)
