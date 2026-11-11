// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskDraw",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeskDraw",
            path: "Sources/DeskDraw",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DeskDrawTests",
            dependencies: ["DeskDraw"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
