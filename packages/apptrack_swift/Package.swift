// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppTrack",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "AppTrack", targets: ["AppTrack"]),
    ],
    targets: [
        .target(name: "AppTrack"),
        .testTarget(name: "AppTrackTests", dependencies: ["AppTrack"]),
    ]
)
