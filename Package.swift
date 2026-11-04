// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Feedpulse",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Feedpulse", targets: ["Feedpulse"]),
    ],
    targets: [
        .target(name: "Feedpulse"),
        .testTarget(name: "FeedpulseTests", dependencies: ["Feedpulse"]),
    ]
)
