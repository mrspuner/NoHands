// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoHands",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .executable(name: "nohands", targets: ["CLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.8"),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Core"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["Core"],
            path: "CLI"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["CLI"],
            path: "Tests/CLITests"
        ),
    ]
)
