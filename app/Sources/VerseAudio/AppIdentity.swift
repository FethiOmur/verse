import Foundation

/// The bundle identifier of the Verse app. It is the name of the app's `UserDefaults` suite and of its Keychain-adjacent
/// and cache locations, so changing it makes an installed copy lose its settings. `VerseApp/Info.plist` carries the same
/// value (a plist cannot read this constant); everything in code derives from here.
public enum AppIdentity {
    public static let bundleID = "dev.fethiverse.verse"
}
