import Foundation
import SwiftUI

/// Stable preference values; the language names are written in their own
/// language so the picker remains usable after an accidental switch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.tr("跟随系统", "System default")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    static let preferenceKey = "app.language"

    static func saved(in defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let language = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if language == "zh" || language.hasPrefix("zh-") { return .simplifiedChinese }
            if language == "en" || language.hasPrefix("en-") { return .english }
        }
        return .english
    }
}

/// A single language snapshot is also available to background OCR and
/// networking error paths, which cannot access a main-actor view model.
enum L10n {
    /// Scoped language for deterministic previews and concurrent tests;
    /// normal app calls use the persisted, process-wide selection.
    @TaskLocal static var overrideLanguage: AppLanguage?
    private static let lock = NSLock()
    private static var current = AppLanguage.saved(in: .standard).resolved()

    static var language: AppLanguage {
        if let overrideLanguage { return overrideLanguage.resolved() }
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    static func tr(_ chinese: String, _ english: String) -> String {
        language == .simplifiedChinese ? chinese : english
    }

    fileprivate static func use(_ language: AppLanguage) {
        lock.lock()
        current = language
        lock.unlock()
    }
}

extension Notification.Name {
    static let tactLanguageDidChange = Notification.Name("Tact.languageDidChange")
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings(defaults: .standard, appliesToApplication: true)

    @Published var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: AppLanguage.preferenceKey)
            refresh()
        }
    }
    @Published private(set) var resolvedLanguage: AppLanguage
    private let defaults: UserDefaults
    private let appliesToApplication: Bool
    private var localeObserver: NSObjectProtocol?

    var locale: Locale { Locale(identifier: resolvedLanguage.rawValue) }

    init(defaults: UserDefaults, appliesToApplication: Bool = false) {
        self.defaults = defaults
        self.appliesToApplication = appliesToApplication
        let saved = AppLanguage.saved(in: defaults)
        selection = saved
        resolvedLanguage = saved.resolved()
        if appliesToApplication { L10n.use(resolvedLanguage) }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
    }

    private func refresh() {
        let resolved = selection.resolved()
        guard resolved != resolvedLanguage else { return }
        // Update synchronous/background lookups before rebuilding any views.
        if appliesToApplication { L10n.use(resolved) }
        resolvedLanguage = resolved
        if appliesToApplication {
            NotificationCenter.default.post(name: .tactLanguageDidChange, object: self)
        }
    }
}

/// Rebuild AppKit-backed controls and cached settings panes when the
/// language changes. Their observable models retain edits and selections.
struct LocalizedContent<Content: View>: View {
    @ObservedObject private var language = LanguageSettings.shared
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .environment(\.locale, language.locale)
            .id(language.resolvedLanguage)
    }
}
