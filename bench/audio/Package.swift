// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Embed an Info.plist (usage descriptions) into the CLI binary so TCC prompts have text to show.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlist = packageDir + "/Support/Info.plist"

let package = Package(
    name: "TapProbe",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "TapProbe",
            path: "Sources/TapProbe",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
