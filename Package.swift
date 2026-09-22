// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "StemDrop",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "StemDrop",
            path: "Sources/StemDrop",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .testTarget(
            name: "StemDropTests",
            dependencies: ["StemDrop"],
            path: "Tests/StemDropTests",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        )
    ]
)
