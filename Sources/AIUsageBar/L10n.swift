import Foundation

/// UI language. `system` follows the user's preferred language (Korean → ko, else en).
enum Lang: String, CaseIterable {
    case system, ko, en
}

enum L {
    static var setting: Lang {
        get { Lang(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }

    /// Resolved language: "ko" or "en".
    static var current: Lang {
        switch setting {
        case .ko, .en: return setting
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ko") ? .ko : .en
        }
    }

    /// Pick the string for the current language.
    static func s(_ ko: String, _ en: String) -> String { current == .ko ? ko : en }
}

/// A string carried in both languages so it can be resolved when rendered
/// (errors are created at fetch time but shown later, possibly after a language switch).
struct LText: Equatable {
    let ko: String
    let en: String
    init(_ ko: String, _ en: String) { self.ko = ko; self.en = en }
    init(same: String) { ko = same; en = same }
    var s: String { L.s(ko, en) }
}
