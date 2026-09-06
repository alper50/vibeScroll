import Foundation

/// One piece of teaching content, served by the backend for a topic.
///
/// Decoding is lenient by design: the backend will grow fields faster than the
/// shipped app can be updated, so every field beyond `id`/`category`/`title`/
/// `body` is optional and unknown keys are ignored. An old client must keep
/// rendering new content.
public struct InfoCard: Codable, Sendable, Equatable, Identifiable {
    public enum Level: String, Codable, Sendable, CaseIterable {
        case beginner, intermediate, advanced
    }

    public let id: String
    public let category: TopicCategory
    public let title: String
    /// Body text. Plain text or light markdown (`**bold**`, `` `code` ``); the
    /// renderer treats anything it doesn't understand as literal text.
    public let body: String
    public let level: Level
    public let tags: [String]
    /// Optional "read more" destination.
    public let link: URL?
    /// Attribution shown in small print, when the card quotes a source.
    public let source: String?

    public init(
        id: String, category: TopicCategory, title: String, body: String,
        level: Level = .beginner, tags: [String] = [], link: URL? = nil, source: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.body = body
        self.level = level
        self.tags = tags
        self.link = link
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, title, body, level, tags, link, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        // An unknown category from a newer backend degrades to `.generic`
        // instead of failing the whole payload.
        let rawCategory = try c.decode(String.self, forKey: .category)
        category = TopicCategory(rawValue: rawCategory) ?? .generic
        let rawLevel = try c.decodeIfPresent(String.self, forKey: .level)
        level = rawLevel.flatMap(Level.init(rawValue:)) ?? .beginner
        tags = ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil) ?? []
        link = ((try? c.decodeIfPresent(String.self, forKey: .link)) ?? nil).flatMap(URL.init(string:))
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil
    }
}

/// A topic's worth of cards, as returned by `GET /v1/cards`.
public struct CardBundle: Codable, Sendable, Equatable {
    /// Server-side content version. The client sends it back as `since` so an
    /// unchanged catalogue answers 304 instead of re-sending every card.
    public let version: String
    public let cards: [InfoCard]

    public init(version: String, cards: [InfoCard]) {
        self.version = version
        self.cards = cards
    }
}
