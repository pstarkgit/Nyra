// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexVoice",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CodexVoice", targets: ["CodexVoice"]),
    ],
    targets: [
        .target(
            name: "CodexVoice",
            path: "Sources/CodexVoice"
        ),
        .testTarget(
            name: "CodexVoiceTests",
            dependencies: ["CodexVoice"],
            path: "Tests/CodexVoiceTests"
        ),
    ]
)
