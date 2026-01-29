// swift-tools-version: 5.5
import PackageDescription

let package = Package(
    name: "SecureNodeSDK",
    platforms: [
        .iOS(.v13)
    ],
    products: [
            	.library(
            name: "SecureNodeSDK",
            targets: ["SecureNodeSDK"]
        ),
    ],
    dependencies: [
        // No external dependencies - uses Foundation and URLSession
    ],
    targets: [
        .target(
            name: "SecureNodeSDK",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "SecureNodeSDKTests",
            dependencies: ["SecureNodeSDK"]
        ),
    ]
)

