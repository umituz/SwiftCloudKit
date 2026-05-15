// swift-tools-version: 5.9

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
    targets: [
        .target(
            name: "SwiftCloudKit",
            dependencies: [],
            path: "Sources/SwiftCloudKit",
            swiftSettings: [
                .unsafeFlags(["-warn-concurrency"])
            ]
        ),
        .testTarget(
            name: "SwiftCloudKitTests",
            dependencies: ["SwiftCloudKit"],
            path: "Tests/SwiftCloudKitTests"
        )
    ]
)
