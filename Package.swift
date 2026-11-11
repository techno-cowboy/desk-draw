// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskDraw",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "DeskDraw",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DeskDraw",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "DeskDrawTests",
            dependencies: ["DeskDraw"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
