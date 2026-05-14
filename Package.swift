// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftCloudKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftCloudKit",
            targets: ["SwiftCloudKit"])
    ],
    dependencies: [
        // Add external dependencies here if needed
    ],
    targets: [
        .target(
            name: "SwiftCloudKit",
            dependencies: [],
            path: "Sources/SwiftCloudKit"),
        .testTarget(
            name: "SwiftCloudKitTests",
            dependencies: ["SwiftCloudKit"],
            path: "Tests/SwiftCloudKitTests")
    ]
)
