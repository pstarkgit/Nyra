// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nyra",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Nyra", targets: ["CodexVoice"]),
        .executable(name: "NovaSonicCanary", targets: ["NovaSonicCanary"]),
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
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSPolly", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
            ],
            path: "Sources/CodexVoice"
        ),
        .executableTarget(
            name: "NovaSonicCanary",
            dependencies: [
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
            ],
            path: "Tools/NovaSonicCanary"
        ),
        .testTarget(
            name: "CodexVoiceTests",
            dependencies: ["CodexVoice"],
            path: "Tests/CodexVoiceTests"
        ),
    ]
)
