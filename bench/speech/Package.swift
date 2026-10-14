// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeechBench",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "SpeechBench",
            path: "Sources/SpeechBench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
