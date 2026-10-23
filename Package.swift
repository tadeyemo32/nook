// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nook",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "NookXPC",
            path: "Sources/NookXPC"
        ),
        .executableTarget(
            name: "Nook",
            dependencies: ["NookXPC"],
            path: "Sources/Nook"
        ),
        .executableTarget(
            name: "NookHelper",
            dependencies: ["NookXPC"],
            path: "Sources/NookHelper"
        ),
        .testTarget(
            name: "NookTests",
            dependencies: ["Nook"],
            path: "Tests/NookTests"
        ),
    ]
)
