import Foundation

/// UI strings. English text is the key; other languages live in Resources/<lang>.lproj/Localizable.strings.
/// `Settings.language` ("system", "en", "ja") selects the bundle at runtime so the UI can switch immediately.
@MainActor
enum L10n {
    static let available = ["system", "en", "ja"]

    static var bundle: Bundle {
        var code = Settings.shared.language
        if code == "system" { code = Bundle.main.preferredLocalizations.first ?? "en" }
        if let p = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: p) { return b }
        return .main
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func name(of code: String) -> String {
        switch code {
        case "ja": return "日本語"
        case "en": return "English"
        default: return string("System")
        }
    }
}

@MainActor
func L(_ key: String) -> String { L10n.string(key) }

@MainActor
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L10n.string(key), arguments: args) }
