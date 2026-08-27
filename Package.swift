// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexVoice",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "CodexVoice", targets: ["CodexVoice"]),
    ],
    targets: [
        .executableTarget(
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
