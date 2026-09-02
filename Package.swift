// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoHands",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Dictation", targets: ["Dictation"]),
        .executable(name: "nohands", targets: ["CLI"]),
        .executable(name: "NoHandsApp", targets: ["App"]),
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
        .target(
            name: "Dictation",
            dependencies: ["Core"],
            path: "Features/Dictation"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["Core", "Dictation"],
            path: "CLI"
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Core", "Dictation"],
            path: "App",
            // Info.plist belongs to the bundle the script assembles, not to the binary; without
            // this SwiftPM treats it as an unhandled resource and warns on every build.
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "DictationTests",
            dependencies: ["Dictation"],
            path: "Tests/DictationTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["CLI"],
            path: "Tests/CLITests"
        ),
    ]
)
