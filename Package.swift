// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "morrow-scribe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MorrowScribeCore", targets: ["MorrowScribeCore"]),
        .executable(name: "morrow-scribe", targets: ["morrow-scribe"]),
    ],
    targets: [
        .target(name: "MorrowScribeCore"),
        .executableTarget(name: "morrow-scribe", dependencies: ["MorrowScribeCore"]),
    ]
)
