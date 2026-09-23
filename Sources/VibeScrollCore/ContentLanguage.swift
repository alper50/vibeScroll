import Foundation

/// The language the catalogue is requested in.
///
/// Must stay in sync with `LANGUAGES` in the backend's `src/catalog.js`, and
/// with the `.lproj` folders under `Resources/Localization`: the card text and
/// the interface around it should never be in two different languages.
///
/// The device decides, not a setting. macOS already has one — System Settings
/// → Language & Region, including a per-app override — and it lands in
/// `Locale.preferredLanguages`, which is the same list AppKit resolves the
/// interface's `.lproj` from. Reading that list with the same rule keeps the
/// two in step without a second place to change the language.
public enum ContentLanguage: String, Codable, Sendable, CaseIterable {
    case en
    case tr

    /// What a device preferring none of the supported languages gets.
    public static let fallback: ContentLanguage = .en

    /// The first supported language in `preferredLanguages`, or `fallback`.
    ///
    /// Only the primary subtag is compared — `tr-TR` and `tr` are the same
    /// catalogue — and order is respected, so a device set to German then
    /// Turkish gets Turkish rather than the fallback.
    public static func resolve(preferredLanguages: [String]) -> ContentLanguage {
        for identifier in preferredLanguages {
            let primary = identifier
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map { $0.lowercased() } ?? ""
            if let language = ContentLanguage(rawValue: primary) { return language }
        }
        return fallback
    }

    /// The `Accept-Language` value for this language.
    ///
    /// The fallback is named explicitly with a lower weight, so a server that
    /// does not carry this language yet answers in English rather than
    /// guessing.
    public var acceptLanguageHeader: String {
        self == Self.fallback ? rawValue : "\(rawValue), \(Self.fallback.rawValue);q=0.5"
    }
}
