// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoHands",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Dictation", targets: ["Dictation"]),
        .library(name: "Meetings", targets: ["Meetings"]),
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
            path: "Core",
            // The summary script travels with the module so tests, the CLI and the app all find
            // it the same way — `Bundle.module`. `Scripts/make-app.sh` copies the generated
            // bundle into the app, or the built application would be the only one that cannot.
            resources: [.copy("LLM/summarize.py")]
        ),
        .target(
            name: "Dictation",
            dependencies: ["Core"],
            path: "Features/Dictation"
        ),
        .target(
            name: "Meetings",
            dependencies: ["Core"],
            path: "Features/Meetings"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["Core", "Dictation", "Meetings"],
            path: "CLI"
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Core", "Dictation", "Meetings"],
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
            name: "MeetingsTests",
            dependencies: ["Meetings"],
            path: "Tests/MeetingsTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["CLI"],
            path: "Tests/CLITests"
        ),
    ]
)
