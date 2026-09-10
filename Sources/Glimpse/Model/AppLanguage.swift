import Foundation

/// The languages the app ships. `system` follows the macOS preferred-language order;
/// anything else pins the UI by writing `AppleLanguages` into the app's own defaults
/// domain, which macOS reads at launch — hence the "restart to apply".
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case italian = "it"
    case spanish = "es"
    case german = "de"
    case portuguese = "pt"
    case russian = "ru"
    case ukrainian = "uk"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case french = "fr"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    /// Endonyms: each language names itself, so the list stays usable no matter
    /// which language the UI happens to be in right now.
    var displayName: String {
        switch self {
        case .system: return L("prefs.language.system")
        case .english: return "English"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .ukrainian: return "Українська"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .french: return "Français"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    /// Written to the app's defaults domain; read by macOS on the next launch.
    func apply() {
        let d = UserDefaults.standard
        if self == .system {
            d.removeObject(forKey: "AppleLanguages")
        } else {
            d.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
