// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ChargingPowerTool",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ChargingPowerTool",
            targets: ["ChargingPowerTool"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ChargingPowerTool"
        ),
    ]
)
