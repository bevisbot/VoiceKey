// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceKey",
    platforms: [
        .macOS("26.0") // 需要 macOS 26 的 Foundation Models 框架
    ],
    targets: [
        .executableTarget(
            name: "VoiceKey",
            path: "Sources/VoiceKey"
        )
    ]
)
