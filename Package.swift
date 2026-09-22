// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nyra",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Nyra", targets: ["CodexVoice"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/awslabs/aws-sdk-swift.git",
            exact: "1.7.71"
        ),
    ],
    targets: [
        .executableTarget(
            name: "CodexVoice",
            dependencies: [
                .product(name: "AWSPolly", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
            ],
            path: "Sources/CodexVoice"
        ),
        .testTarget(
            name: "CodexVoiceTests",
            dependencies: ["CodexVoice"],
            path: "Tests/CodexVoiceTests"
        ),
    ]
)
