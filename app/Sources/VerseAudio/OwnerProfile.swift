import Foundation

/// The owner profile: the one place where values that belong to one person's machine live. The repository carries no
/// personal name, home path or private project name; they are read from a local, untracked JSON file,
///
///     ~/Library/Application Support/Verse/owner.json      (override the location with `VERSE_OWNER_FILE`)
///
/// The brain reads the same file (`brain/verse_brain/owner.py`, which documents every key). The app uses:
///
///     display_name   how the app and the prompts name the user. Default: "the user".
///     vault_path     a notes vault the app can write summaries to. Default: none (the vault features stay off).
///     api_key_note   one sentence shown above the Keychain note on the Settings page. Default: none.
///
/// A missing, unreadable or malformed file gives the generic profile; nothing here throws.
public struct OwnerProfile: Sendable, Equatable {
    public static let environmentKey = "VERSE_OWNER_FILE"
    public static let genericName = "the user"

    public var displayName: String = OwnerProfile.genericName
    /// The profile gave a display name.
    public var named: Bool = false
    /// As written in the file (a leading `~` is not expanded). nil: no vault.
    public var vaultPath: String?
    public var apiKeyNote: String?

    public init(displayName: String = OwnerProfile.genericName, named: Bool = false, vaultPath: String? = nil,
                apiKeyNote: String? = nil) {
        self.displayName = displayName
        self.named = named
        self.vaultPath = vaultPath
        self.apiKeyNote = apiKeyNote
    }

    /// The name the turn logic matches against what the other side says: empty without a profile name, so that a generic
    /// label can never be mistaken for the user's name.
    public var addresseeName: String { named ? displayName : "" }

    /// The `src` tag of a line the user wrote himself in `me.md` (`| <tag>` at the end of the line).
    public var sourceTag: String {
        guard named else { return "owner" }
        var out = ""
        var pendingDash = false
        for ch in displayName.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "owner" : out
    }

    /// The `me.md` section that holds the user's own notes.
    public var notesHeading: String { named ? "\(displayName.uppercased())'S NOTES" : "MY NOTES" }

    public static var fileURL: URL {
        if let p = ProcessInfo.processInfo.environment[environmentKey], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Verse/owner.json")
    }

    public static func load(from url: URL) -> OwnerProfile {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return OwnerProfile() }
        func str(_ key: String) -> String? {
            guard let s = obj[key] as? String else { return nil }
            let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return t.isEmpty ? nil : t
        }
        let name = str("display_name")
        return OwnerProfile(displayName: name ?? genericName, named: name != nil, vaultPath: str("vault_path"),
                            apiKeyNote: str("api_key_note"))
    }

    /// The profile of this process, read once (the first use).
    public static let current: OwnerProfile = load(from: fileURL)
}
