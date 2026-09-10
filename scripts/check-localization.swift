// Pre-publication guard for the translations.
//
//   swift scripts/check-localization.swift     (or: make check)
//
// Verifies that every .lproj has the same keys as English, that the %-placeholders
// survived translation, that every L("key") used in the sources exists, and that
// Info.plist's CFBundleLocalizations matches the folders actually shipped.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let localizationDir = root.appendingPathComponent("Resources/Localization")
let sourcesDir = root.appendingPathComponent("Sources")
let infoPlist = root.appendingPathComponent("Resources/Info.plist")

var problems: [String] = []
func fail(_ message: String) { problems.append(message) }

/// The plist parser keeps the last of a duplicated pair, so the key set — and the
/// count — look right while the visible string is whatever came second.
func duplicateKeys(in url: URL) -> [String] {
    guard var text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    // Strip /* */ blocks first: translators park rejected wordings in them, and a
    // commented-out key is not a duplicate.
    let comments = try! NSRegularExpression(pattern: "/\\*.*?\\*/", options: [.dotMatchesLineSeparators])
    text = comments.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                             withTemplate: "")
    let pattern = try! NSRegularExpression(pattern: "^\\s*\"([^\"]+)\"\\s*=", options: [.anchorsMatchLines])
    var seen = Set<String>(), duplicated: [String] = []
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let r = Range(match.range(at: 1), in: text) else { continue }
        let key = String(text[r])
        if !seen.insert(key).inserted { duplicated.append(key) }
    }
    return duplicated
}

func strings(at url: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = plist as? [String: String]
    else {
        fail("\(url.lastPathComponent): could not be parsed as a .strings file")
        return [:]
    }
    return dict
}

/// The `%@`, `%d`, `%1$@`… tokens a translation has to keep, sorted for comparison.
func placeholders(in value: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: "%[0-9]*\\$?[@a-zA-Z]")
    let range = NSRange(value.startIndex..., in: value)
    return pattern.matches(in: value, range: range)
        .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
        .sorted()
}

// MARK: Locales present

let locales = ((try? FileManager.default.contentsOfDirectory(atPath: localizationDir.path)) ?? [])
    .filter { $0.hasSuffix(".lproj") }
    .map { String($0.dropLast(".lproj".count)) }
    .sorted()

guard locales.contains("en") else {
    print("✗ no en.lproj — nothing to compare against")
    exit(1)
}

let referenceFile = localizationDir.appendingPathComponent("en.lproj/Localizable.strings")
let reference = strings(at: referenceFile)
let referenceKeys = Set(reference.keys)

// English is what everything else is diffed against, so a duplicate or an empty
// value here is worse than in a translation, not exempt from checking.
for key in duplicateKeys(in: referenceFile) {
    fail("en: \"\(key)\" appears more than once — the last one silently wins")
}
for (key, value) in reference where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    fail("en: \"\(key)\" is empty")
}

// The keys worth translating in Info.plist: the usage descriptions macOS shows.
var infoPlistKeys: Set<String> = []
if let data = try? Data(contentsOf: infoPlist),
   let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
    infoPlistKeys = Set(info.keys.filter { $0.hasSuffix("UsageDescription") })
}
if infoPlistKeys.isEmpty { fail("Info.plist declares no usage descriptions to translate") }

// MARK: Keys and placeholders per locale

for locale in locales where locale != "en" {
    let dir = localizationDir.appendingPathComponent("\(locale).lproj")
    let translated = strings(at: dir.appendingPathComponent("Localizable.strings"))

    for key in referenceKeys.subtracting(translated.keys).sorted() {
        fail("\(locale): missing key \"\(key)\"")
    }
    for key in Set(translated.keys).subtracting(referenceKeys).sorted() {
        fail("\(locale): unknown key \"\(key)\" (not in English)")
    }
    for key in referenceKeys.intersection(translated.keys).sorted() {
        let expected = placeholders(in: reference[key]!)
        let actual = placeholders(in: translated[key]!)
        if expected != actual {
            fail("\(locale): \"\(key)\" has placeholders \(actual), English has \(expected)")
        }
        if translated[key]!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("\(locale): \"\(key)\" is empty")
        }
    }
    for key in duplicateKeys(in: dir.appendingPathComponent("Localizable.strings")) {
        fail("\(locale): \"\(key)\" appears more than once — the last one silently wins")
    }
    let infoStrings = dir.appendingPathComponent("InfoPlist.strings")
    if !FileManager.default.fileExists(atPath: infoStrings.path) {
        fail("\(locale): missing InfoPlist.strings")
    } else {
        // A typo here silently falls back to English in a system permission dialog,
        // which is the most visible place in the app to be untranslated.
        let translatedInfo = Set(strings(at: infoStrings).keys)
        for key in infoPlistKeys.subtracting(translatedInfo).sorted() {
            fail("\(locale): InfoPlist.strings does not translate \(key)")
        }
        for key in translatedInfo.subtracting(infoPlistKeys).sorted() {
            fail("\(locale): InfoPlist.strings has \(key), which Info.plist does not declare")
        }
    }
}

// English is skipped above because it IS the reference for Localizable.strings —
// but not for InfoPlist.strings, which macOS shows in the system permission prompt
// and falls back to for every locale. It was the one file nothing checked.
let englishInfo = localizationDir.appendingPathComponent("en.lproj/InfoPlist.strings")
if !FileManager.default.fileExists(atPath: englishInfo.path) {
    fail("en: missing InfoPlist.strings")
} else {
    let translatedInfo = strings(at: englishInfo)
    for key in infoPlistKeys.subtracting(translatedInfo.keys).sorted() {
        fail("en: InfoPlist.strings does not translate \(key)")
    }
    for key in Set(translatedInfo.keys).subtracting(infoPlistKeys).sorted() {
        fail("en: InfoPlist.strings has \(key), which Info.plist does not declare")
    }
    for (key, value) in translatedInfo where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        fail("en: InfoPlist.strings value for \(key) is empty")
    }
}

// MARK: Keys used by the code

let swiftFiles = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)?
    .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

/// Collects every string literal inside an `L(…)` call, so both `L("key")` and the
/// `L(flag ? "a" : "b")` form are counted. Parentheses are balanced by hand because
/// a regex cannot see where the call ends.
func localizationKeys(in source: String) -> Set<String> {
    var keys = Set<String>()
    let chars = Array(source)
    var i = 0
    while i < chars.count {
        // An `L(` that is not part of a longer identifier.
        guard chars[i] == "L", i + 1 < chars.count, chars[i + 1] == "(",
              i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_")
        else { i += 1; continue }

        var depth = 0
        var j = i + 1
        while j < chars.count {
            switch chars[j] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { i = j; break }
            case "\"":
                var literal = ""
                // Interpolated strings are runtime values, not keys. This has to be
                // noticed before the escape is skipped, or "\\(" never survives.
                var interpolated = false
                j += 1
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\" {
                        if j + 1 < chars.count, chars[j + 1] == "(" { interpolated = true }
                        j += 1
                    }
                    if j < chars.count { literal.append(chars[j]) }
                    j += 1
                }
                if !interpolated { keys.insert(literal) }
            default: break
            }
            if depth == 0 { break }
            j += 1
        }
        i = max(i, j) + 1
    }
    return keys
}

var used = Set<String>()
for file in swiftFiles {
    guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
    used.formUnion(localizationKeys(in: source))
}

for key in used.subtracting(referenceKeys).sorted() {
    fail("code uses L(\"\(key)\") but English has no such key")
}
for key in referenceKeys.subtracting(used).sorted() {
    fail("unused key \"\(key)\" — no L(\"\(key)\") anywhere in Sources")
}

// MARK: Info.plist

if let data = try? Data(contentsOf: infoPlist),
   let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
    let declared = (info["CFBundleLocalizations"] as? [String] ?? []).sorted()
    if declared != locales {
        fail("Info.plist CFBundleLocalizations is \(declared), folders are \(locales)")
    }
} else {
    fail("Info.plist could not be read")
}

// MARK: AppLanguage

// CONTRIBUTING tells translators they need no Swift, then asks them for one Swift
// edit: a case in AppLanguage. Miss it and the language ships but the picker never
// offers it; add it without the folder and the picker writes AppleLanguages for a
// language that is not there. The unit tests catch both, but those need full Xcode,
// which is exactly what a translator was promised they would not need.
let appLanguage = root.appendingPathComponent("Sources/Glimpse/Model/AppLanguage.swift")
if let raw = try? String(contentsOf: appLanguage, encoding: .utf8) {
    // Comments first, so a case parked inside one is not read as a declaration.
    // Block comments nest in Swift, so the depth is counted rather than flagged.
    // Anything this scanner cannot make sense of is reported, never guessed at:
    // silently mis-parsing this file is how a missing language would ship.
    func stripComments(_ text: String) -> (code: String, unterminated: Bool) {
        var out = ""
        var blockDepth = 0
        var inLine = false, inString = false, escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i) < text.endIndex ? text[text.index(after: i)] : nil
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if blockDepth > 0 {
                if c == "/", next == "*" { blockDepth += 1; i = text.index(after: i) }
                else if c == "*", next == "/" { blockDepth -= 1; i = text.index(after: i) }
                else if c == "\n" { out.append(c) }
            } else if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                else if c == "\n" { inString = false }   // a literal cannot span a line
            } else if c == "/", next == "/" {
                inLine = true; i = text.index(after: i)
            } else if c == "/", next == "*" {
                blockDepth += 1; i = text.index(after: i)
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            i = text.index(after: i)
        }
        return (out, blockDepth > 0)
    }

    let (code, unterminated) = stripComments(raw)
    if unterminated { fail("AppLanguage.swift has an unterminated block comment") }

    // No brace matching, and no attempt to find the enum body: counting braces meant
    // one brace inside a string literal took the whole check down. Instead, collect
    // every `= "value"` whose value has the shape of a locale code. `displayName`
    // returns endonyms with `: return "..."`, which has no `=`, and an unrelated raw
    // value like "AppleLanguages" is not locale-shaped.
    // BCP-47 allows several subtags and digits: zh-Hant-TW, sr-Latn-RS, es-419 are
    // all legal, and a check that rejected them told a translator who had done
    // everything right that they had forgotten the enum case.
    let localeShape = try! NSRegularExpression(pattern: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$")
    // The `case` keyword is required. Matching a bare `= "..."` also matched the
    // second half of `==`, and any unrelated `let x = "fr"` in the file, which
    // failed the check on correct code.
    let one = "[A-Za-z_][A-Za-z0-9_]*\\s*=\\s*\"[^\"\\n]*\""
    let clause = try! NSRegularExpression(pattern: "\\bcase\\s+\(one)(?:\\s*,\\s*\(one))*")
    let quoted = try! NSRegularExpression(pattern: "\"([^\"\\n]*)\"")
    let ns = code as NSString
    var declared: Set<String> = []
    for m in clause.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
        // One clause may declare several: `case a = "x", b = "y"`.
        let text = ns.substring(with: m.range)
        let sub = text as NSString
        for q in quoted.matches(in: text, range: NSRange(location: 0, length: sub.length)) {
            let value = sub.substring(with: q.range(at: 1))
            let vns = value as NSString
            guard localeShape.firstMatch(in: value, range: NSRange(location: 0, length: vns.length)) != nil
            else { continue }
            declared.insert(value)
        }
    }
    if declared.isEmpty {
        fail("AppLanguage.swift declared no languages, which cannot be right")
    }
    for locale in locales where !declared.contains(locale) {
        fail("\(locale).lproj exists but AppLanguage has no case for it, so the picker cannot reach it")
    }
    for code in declared.subtracting(locales).sorted() {
        fail("AppLanguage offers \"\(code)\" but there is no \(code).lproj folder")
    }
} else {
    fail("AppLanguage.swift could not be read")
}

// MARK: Result

if problems.isEmpty {
    print("✓ \(locales.count) locales, \(referenceKeys.count) keys, all consistent")
    exit(0)
}
for problem in problems { print("✗ \(problem)") }
print("\(problems.count) problem(s)")
exit(1)
