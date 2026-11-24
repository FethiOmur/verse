import AppKit
import SwiftUI

/// The last app in front other than Verse (gap G12): opening the menu-bar menu does not bring Verse forward, but its
/// Settings window can, so the menu's per-app rows name the app dictation would type into.
@MainActor
public final class DictationFrontAppTracker: ObservableObject {
    public struct App: Sendable, Equatable {
        public var bundleID: String
        public var name: String
        public init(bundleID: String, name: String) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    @Published public private(set) var app: App?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// `observe`: follow app activations (the app); tests set `app` themselves.
    public init(observe: Bool = true) {
        app = Self.app(NSWorkspace.shared.frontmostApplication)
        guard observe else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            let found = Self.app(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            MainActor.assumeIsolated {
                if let found { self?.app = found }
            }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func set(_ app: App?) { self.app = app }

    nonisolated static func app(_ running: NSRunningApplication?) -> App? {
        guard let running, let id = running.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
        return App(bundleID: id, name: running.localizedName ?? id)
    }
}

/// The menu-bar menu's "Dictation language" submenu (gap G12), while dictation is on and no run is active: the default
/// language with a checkmark (switching at once: the next dictation listens in it), then, for the last app in front, "Always
/// use <language> in <app>" for each language (checked when set) and "Use default in <app>" when one is set.
public struct DictationLanguageMenu: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var settings: DictationSettings
    @ObservedObject var frontApp: DictationFrontAppTracker

    public init(dictation: DictationController) {
        self.dictation = dictation
        settings = dictation.settings
        frontApp = dictation.frontApp
    }

    static func alwaysUseLabel(_ lang: String, app: String) -> String {
        let name = StartRoutes.languageName(lang)
        return L10n.tr("Always use \(name) in \(app)")
    }

    static func useDefaultLabel(app: String) -> String { L10n.tr("Use default in \(app)") }

    public var body: some View {
        if settings.enabled && !dictation.runActive {
            Menu {
                Picker(selection: $settings.language) {
                    ForEach(DictationSettings.languages, id: \.self) { Text(verbatim: StartRoutes.languageName($0)).tag($0) }
                } label: { Text("Default language", bundle: L10n.bundle) }
                .pickerStyle(.inline)
                if let app = frontApp.app {
                    Divider()
                    let current = settings.appLanguages[app.bundleID]
                    ForEach(DictationSettings.languages, id: \.self) { lang in
                        Toggle(isOn: Binding(get: { current == lang },
                                             set: { settings.setLanguage($0 ? lang : nil, forApp: app.bundleID) })) {
                            Text(verbatim: Self.alwaysUseLabel(lang, app: app.name))
                        }
                    }
                    if current != nil {
                        Button { settings.setLanguage(nil, forApp: app.bundleID) } label: {
                            Text(verbatim: Self.useDefaultLabel(app: app.name))
                        }
                    }
                }
            } label: { Text("Dictation language", bundle: L10n.bundle) }
            Divider()
        }
    }
}
