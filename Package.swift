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
        .systemLibrary(
            name: "CSQLite",
            path: "packages/ios/Sources/CSQLite"
        ),
        .target(
            name: "OnloSDK",
            dependencies: ["CSQLite"],
            path: "packages/ios/Sources/OnloSDK"
        ),
        .testTarget(
            name: "OnloSDKTests",
            dependencies: ["OnloSDK"],
            path: "packages/ios/Tests/OnloSDKTests"
        ),
    ]
)
