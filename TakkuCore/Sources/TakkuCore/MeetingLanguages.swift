import Foundation

/// The languages a Meeting can be in, ticked in Settings. Detection picks only among them; with
/// one ticked it is forced and there is no detection.
public enum MeetingLanguages {
    /// The languages both engines handle (those of Parakeet v3), in the order of the Settings list:
    /// Italian and English first, then by English name. The first one ticked is the fallback when
    /// nothing can be detected.
    public static let offered = ["it", "en"] + [
        "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el", "hu", "lv", "lt", "mt", "pl", "pt", "ro",
        "ru", "sk", "sl", "es", "sv", "uk",
    ]

    /// What v1 did: Italian or English. Also what is left when nothing offered is ticked.
    public static let v1 = ["it", "en"]

    /// Only offered languages, once each, in the Settings order; v1's if none is left.
    public static func normalized(_ codes: [String]) -> [String] {
        let ticked = offered.filter(codes.contains)
        return ticked.isEmpty ? v1 : ticked
    }

    /// For a Mac that never chose them: those of the Mac's languages (`Locale.preferredLanguages`,
    /// such as `es-ES`) that Takku offers, and English, spoken in many meetings whatever the Mac's language.
    public static func defaults(macLanguages: [String]) -> [String] {
        normalized(macLanguages.compactMap { Locale.Language(identifier: $0).languageCode?.identifier } + ["en"])
    }

    /// The language's name in the interface language: "Italiano", "French"…
    public static func name(_ code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: .current) + name.dropFirst()
    }

    /// The language to force, when only one is ticked.
    public static func forced(_ codes: [String]) -> String? {
        let ticked = normalized(codes)
        return ticked.count == 1 ? ticked[0] : nil
    }

    /// The language used when detection says nothing.
    public static func fallback(_ codes: [String]) -> String {
        normalized(codes)[0]
    }

    /// The languages of a Takku set up before the defaults followed the Mac: v1's `language`
    /// setting, `it` or `en` forced, otherwise (`auto`, or never chosen) both, with the Mac's languages added.
    public static func migrated(fromLanguageSetting value: String?, macLanguages: [String]) -> [String] {
        guard let value, v1.contains(value) else { return normalized(v1 + defaults(macLanguages: macLanguages)) }
        return [value]
    }
}
