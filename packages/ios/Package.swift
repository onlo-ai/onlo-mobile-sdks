// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnloSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "OnloSDK", targets: ["OnloSDK"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "OnloSDK", dependencies: ["CSQLite"]),
        .testTarget(name: "OnloSDKTests", dependencies: ["OnloSDK"]),
    ]
)
