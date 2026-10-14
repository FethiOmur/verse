// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SttLocal",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Apache-2.0. Pinned to the latest release tag at the time of the run.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "SttLocal",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/SttLocal",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
