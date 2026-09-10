import Foundation

/// Looks a key up in the app bundle's `Localizable.strings`.
///
/// The bundle ships one `.lproj` per supported language; macOS picks the one that
/// matches the user's preferred languages, or the override written to
/// `AppleLanguages` by the language picker in Preferences. Missing keys fall back
/// to the key itself, which makes them obvious during development.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Same, for keys whose English value is a `String(format:)` template.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: .current, arguments: args)
}
