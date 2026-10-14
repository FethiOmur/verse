// swift-tools-version: 6.2
import PackageDescription
import Foundation

// verse-listen embeds an Info.plist (bundle ID + usage descriptions) so the TCC prompts for
// "System Audio Recording" and the microphone have a name and a reason to show.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let listenInfoPlist = packageDir + "/Sources/verse-listen/Info.plist"
let runInfoPlist = packageDir + "/Sources/verse-run/Info.plist"
let appInfoPlist = packageDir + "/Sources/VerseApp/Info.plist"

let package = Package(
    name: "Verse",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VerseAudio", targets: ["VerseAudio"]),
        .library(name: "VerseSpeech", targets: ["VerseSpeech"]),
        .library(name: "VerseTurns", targets: ["VerseTurns"]),
        .executable(name: "verse-listen", targets: ["verse-listen"]),
        .executable(name: "verse-run", targets: ["verse-run"]),
        // P1-5: the menu-bar app (bundled into app/build/Verse.app by scripts/bundle-app.sh).
        .library(name: "VerseUI", targets: ["VerseUI"]),
        .executable(name: "Verse", targets: ["VerseApp"]),
    ],
    dependencies: [
        // Apache-2.0. Local Nemotron Speech Streaming 0.6B (CoreML) engine; same pin as bench/stt-local.
        // The model files are NOT part of the package: they are read from ~/Library/Application Support/Verse/models.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
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
            dependencies: ["VerseAudio", .product(name: "FluidAudio", package: "FluidAudio")],
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
        // P1-4: turn logic (cues, endpoint, addressee, bank matcher, fact chips) and the brain child process.
        .target(
            name: "VerseTurns",
            dependencies: ["VerseSpeech"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "verse-run",
            dependencies: ["VerseTurns"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", runInfoPlist]),
            ]
        ),
        // P1-5: overlay model and views, settings, Keychain store, the app controller.
        .target(
            name: "VerseUI",
            dependencies: ["VerseTurns"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        .executableTarget(
            name: "VerseApp",
            dependencies: ["VerseUI"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", appInfoPlist]),
            ]
        ),
        .testTarget(
            name: "VerseUITests",
            dependencies: ["VerseUI", "VerseTurns"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VerseTurnsTests",
            dependencies: ["VerseTurns", "VerseSpeech", "verse-run"],
            swiftSettings: [.swiftLanguageMode(.v6)]
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
