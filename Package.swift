// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaubMacVoice",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "claub-mac-voice",
            path: "Sources/ClaubMacVoice",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
