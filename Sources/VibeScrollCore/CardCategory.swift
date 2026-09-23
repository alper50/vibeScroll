import Foundation

/// What a card is *about*: the content vocabulary shared with the backend.
///
/// Deliberately a different type from `TopicCategory`. That one describes what
/// an agent is doing and decides *when* a card may appear; this one describes
/// the card and decides nothing about timing. Keeping them apart is what lets
/// the catalogue be anything at all — today it is television — without the
/// event pipeline, the face or the pacing gates noticing.
///
/// Adding a case means adding it here **and** in the backend's `CATEGORIES`.
/// Server-first is safe: `CardBundle` skips a card whose category this build
/// does not know, so an older app simply never shows the new topic.
public enum CardCategory: String, Codable, Sendable, CaseIterable {
    case gameOfThrones
    case breakingBad
    case strangerThings
    case theOffice
    case friends
    case theSopranos
    case sherlock
    case squidGame

    /// Display name. Show titles are proper nouns and ship under the same name
    /// in every language this app supports, so they are not localized.
    public var label: String {
        switch self {
        case .gameOfThrones:  return "Game of Thrones"
        case .breakingBad:    return "Breaking Bad"
        case .strangerThings: return "Stranger Things"
        case .theOffice:      return "The Office"
        case .friends:        return "Friends"
        case .theSopranos:    return "The Sopranos"
        case .sherlock:       return "Sherlock"
        case .squidGame:      return "Squid Game"
        }
    }
}
