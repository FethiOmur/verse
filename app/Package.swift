// swift-tools-version: 6.2
import PackageDescription
import Foundation

// verse-listen embeds an Info.plist (bundle ID + usage descriptions) so the TCC prompts for
// "System Audio Recording" and the microphone have a name and a reason to show.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let listenInfoPlist = packageDir + "/Sources/verse-listen/Info.plist"
let runInfoPlist = packageDir + "/Sources/verse-run/Info.plist"
let appInfoPlist = packageDir + "/Sources/VerseApp/Info.plist"
let meetInfoPlist = packageDir + "/Sources/verse-meet/Info.plist"

let package = Package(
    name: "Verse",
    // L0: the interface language catalog (Sources/VerseUI/Resources/Localizable.xcstrings) is English at the source.
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VerseAudio", targets: ["VerseAudio"]),
        .library(name: "VerseSpeech", targets: ["VerseSpeech"]),
        .library(name: "VerseTurns", targets: ["VerseTurns"]),
        .library(name: "VerseMeet", targets: ["VerseMeet"]),
        // S3: interview-simulation voices (Apple / ElevenLabs / OpenAI / text) behind one protocol.
        .library(name: "VerseVoice", targets: ["VerseVoice"]),
        .library(name: "VersePosting", targets: ["VersePosting"]),
        // T-core: teleprompter logic (script parsing, Textream-derived matcher, scroll drivers, session). No UI.
        .library(name: "VersePrompter", targets: ["VersePrompter"]),
        .executable(name: "verse-listen", targets: ["verse-listen"]),
        .executable(name: "verse-run", targets: ["verse-run"]),
        // P1-5: the menu-bar app (bundled into app/build/Verse.app by scripts/bundle-app.sh).
        .library(name: "VerseUI", targets: ["VerseUI"]),
        .executable(name: "Verse", targets: ["VerseApp"]),
        .executable(name: "verse-meet", targets: ["verse-meet"]),
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
            // S4: the sim runner plays the interviewer through VerseVoice.
            dependencies: ["VerseSpeech", "VerseVoice"],
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
            // S4: the practice-interview setup (posting fetch, voice keys) and report window.
            // T-UI: the teleprompter view, settings and editor use the VersePrompter core.
            // W2: VerseMeet for the "Meeting detected, start?" prompt and calendar-matched sessions.
            dependencies: ["VerseTurns", "VerseVoice", "VersePosting", "VersePrompter", "VerseSpeech", "VerseMeet"],
            // L0: the String Catalog is compiled into Verse_VerseUI.bundle/<lang>.lproj/Localizable.strings.
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("ScreenCaptureKit"), .linkedFramework("WebKit"), .linkedFramework("Carbon")]
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
            dependencies: ["VerseUI", "VerseTurns", "VerseVoice", "VersePrompter", "VerseSpeech", "VerseMeet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // F5: calendar prep (EventKit) and meeting detection (Core Audio process input flags).
        .target(
            name: "VerseMeet",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "verse-meet",
            dependencies: ["VerseMeet"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", meetInfoPlist]),
            ]
        ),
        // S4a: job-posting fetch (LinkedIn guest API, Ashby, Greenhouse, Lever, generic pages).
        .target(
            name: "VersePosting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VersePostingTests",
            dependencies: ["VersePosting"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // T-core: depends on VerseSpeech (TranscriptEvent, ListenSession) and VerseAudio only.
        .target(
            name: "VersePrompter",
            dependencies: ["VerseSpeech", "VerseAudio"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VersePrompterTests",
            dependencies: ["VersePrompter", "VerseSpeech"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VerseMeetTests",
            dependencies: ["VerseMeet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VerseTurnsTests",
            dependencies: ["VerseTurns", "VerseSpeech", "VerseVoice", "verse-run"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VerseAudioTests",
            dependencies: ["VerseAudio", "VerseSpeech", "verse-listen"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // S3: voices. No dependency on other Verse targets; AVFoundation only.
        .target(
            name: "VerseVoice",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .testTarget(
            name: "VerseVoiceTests",
            dependencies: ["VerseVoice"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VerseSpeechTests",
            dependencies: ["VerseSpeech"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
