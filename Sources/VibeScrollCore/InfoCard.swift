import Foundation

/// One card from the catalogue, already in the language it was requested in.
///
/// Decoding is lenient by design: the backend will grow fields faster than the
/// shipped app can be updated, so every field beyond `id`/`category`/`title`/
/// `body` is optional and unknown keys are ignored. An old client must keep
/// rendering new content.
public struct InfoCard: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let category: CardCategory
    public let title: String
    /// Body text. Plain text or light markdown (`**bold**`, `` `code` ``); the
    /// renderer treats anything it doesn't understand as literal text.
    public let body: String
    public let tags: [String]
    /// Optional "read more" destination.
    public let link: URL?
    /// Attribution shown in small print, when the card quotes a source.
    public let source: String?

    public init(
        id: String, category: CardCategory, title: String, body: String,
        tags: [String] = [], link: URL? = nil, source: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.body = body
        self.tags = tags
        self.link = link
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, title, body, tags, link, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        // An unknown category throws rather than being mapped to a default:
        // there is no neutral topic to hide it under. `CardBundle` catches it
        // and skips just this card.
        category = try c.decode(CardCategory.self, forKey: .category)
        tags = ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil) ?? []
        link = ((try? c.decodeIfPresent(String.self, forKey: .link)) ?? nil).flatMap(URL.init(string:))
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil
    }
}

/// The catalogue as returned by `GET /v1/catalog`.
public struct CardBundle: Codable, Sendable, Equatable {
    /// Server-side content version for this language. The client sends it back
    /// as `If-None-Match` so an unchanged catalogue answers 304.
    public let version: String
    /// The language the server answered in. `nil` from a backend that predates
    /// localization, which only ever served English.
    public let language: ContentLanguage?
    public let cards: [InfoCard]

    public init(version: String, language: ContentLanguage? = nil, cards: [InfoCard]) {
        self.version = version
        self.language = language
        self.cards = cards
    }

    private enum CodingKeys: String, CodingKey {
        case version, language, cards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        language = (try? c.decodeIfPresent(String.self, forKey: .language))
            .flatMap { $0 }
            .flatMap(ContentLanguage.init(rawValue:))
        // One card this build cannot read — a category added server-first, a
        // field that went missing — costs that card, not the catalogue.
        cards = try c.decode([Lossy<InfoCard>].self, forKey: .cards).compactMap(\.value)
    }
}

/// Decodes `Wrapped` or nothing, so one bad element does not fail its array.
private struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
