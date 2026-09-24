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
    case moneyHeist
    case peakyBlinders
    case dark
    case chernobyl
    case blackMirror
    case prisonBreak
    case howIMetYourMother

    /// Display name. Show titles are proper nouns and most ship under the same
    /// name in every language this app supports, so they are not localized.
    /// The exception is a show released under different titles in different
    /// markets: in Turkey Money Heist is known by its original Spanish title,
    /// and a picker row nobody recognises is worse than an inconsistent rule.
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
        case .moneyHeist:
            return String(localized: "show.moneyHeist", defaultValue: "Money Heist")
        case .peakyBlinders:  return "Peaky Blinders"
        case .dark:           return "Dark"
        case .chernobyl:      return "Chernobyl"
        case .blackMirror:    return "Black Mirror"
        case .prisonBreak:    return "Prison Break"
        case .howIMetYourMother: return "How I Met Your Mother"
        }
    }
}
