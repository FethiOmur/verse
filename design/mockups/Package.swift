// swift-tools-version: 6.2
import PackageDescription

// Offscreen renders of the 2026-10 UI redesign (docs/specs/2026-10-16-verse-ui-redesign-design.md).
// `swift run verse-mockups OUT_DIR [name ...]` writes one PNG per mockup and wallpaper. Not part of the app.
let package = Package(
    name: "VerseMockups",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "verse-mockups",
            path: "Sources/VerseMockups",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
    ]
)
