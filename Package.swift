// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "QuotaBarCore", targets: ["QuotaBarCore"]),
        .executable(name: "QuotaBar", targets: ["QuotaBar"])
    ],
    targets: [
        .target(
            name: "QuotaBarCore"
        ),
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaBarCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(name: "QuotaBarAppTests", dependencies: ["QuotaBar", "QuotaBarCore"]),
        .testTarget(
            name: "QuotaBarCoreTests",
            dependencies: ["QuotaBarCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
