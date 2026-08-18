// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "morrow-scribe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MorrowScribeCore", targets: ["MorrowScribeCore"]),
        .executable(name: "morrow-scribe", targets: ["morrow-scribe"]),
        .executable(name: "MorrowScribeApp", targets: ["MorrowScribeApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
    ],
    targets: [
        .target(name: "MorrowScribeCore"),
        .executableTarget(name: "morrow-scribe", dependencies: ["MorrowScribeCore"]),
        .executableTarget(
            name: "MorrowScribeApp",
            dependencies: [
                "MorrowScribeCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
    ]
)
