// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExeStart",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExeStartKit", targets: ["ExeStartKit"]),
        .executable(name: "exestart", targets: ["exestart"]),
        .executable(name: "ExeStartApp", targets: ["ExeStartApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ExeStartKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "exestart",
            dependencies: [
                "ExeStartKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ExeStartApp",
            dependencies: ["ExeStartKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ExeStartKitTests",
            dependencies: ["ExeStartKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
