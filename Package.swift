// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Kuang",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Kuang",
            targets: ["Kuang"]
        )
    ],
    targets: [
        .target(
            name: "Kuang",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "KuangTests",
            dependencies: ["Kuang"]
        )
    ]
)
