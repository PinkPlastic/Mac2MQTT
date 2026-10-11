// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Mac2MQTT",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "Mac2MQTT"
        ),
        .testTarget(
            name: "Mac2MQTTTests",
            dependencies: ["Mac2MQTT"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
