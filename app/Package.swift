// swift-tools-version: 6.2
import PackageDescription
import Foundation

// verse-listen embeds an Info.plist (bundle ID + usage descriptions) so the TCC prompts for
// "System Audio Recording" and the microphone have a name and a reason to show.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let listenInfoPlist = packageDir + "/Sources/verse-listen/Info.plist"

let package = Package(
    name: "Verse",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VerseAudio", targets: ["VerseAudio"]),
        .library(name: "VerseSpeech", targets: ["VerseSpeech"]),
        .executable(name: "verse-listen", targets: ["verse-listen"]),
    ],
    targets: [
        .target(
            name: "VerseAudio",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .target(
            name: "VerseSpeech",
            dependencies: ["VerseAudio"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("Speech")]
        ),
        .executableTarget(
            name: "verse-listen",
            dependencies: ["VerseSpeech"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", listenInfoPlist]),
            ]
        ),
        .testTarget(
            name: "VerseAudioTests",
            dependencies: ["VerseAudio", "VerseSpeech", "verse-listen"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VerseSpeechTests",
            dependencies: ["VerseSpeech"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
