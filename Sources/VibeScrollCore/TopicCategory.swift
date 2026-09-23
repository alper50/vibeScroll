import Foundation

/// What the agent is currently doing, normalised across every supported agent.
///
/// This decides *when* a card appears, not *which* one: a topic has to hold for
/// the dwell time and clear its own cooldown before the scheduler draws from
/// the catalogue, which is described by the separate `CardCategory`. The topic
/// also names the work in the face's remarks and the session context line.
///
/// Keep the set small and behavioural ("what is happening"), not technological
/// ("which language"), so it stays meaningful regardless of stack. It never
/// reaches the backend.
public enum TopicCategory: String, Codable, Sendable, CaseIterable {
    /// Reading source to build context.
    case reading
    /// Writing or editing source.
    case writing
    /// Executing something (build, script, arbitrary shell).
    case running
    /// Searching the codebase (grep/glob/semantic).
    case searching
    /// Running or authoring tests.
    case testing
    /// Git and friends: commit, branch, rebase, diff, PR.
    case versionControl
    /// Installing / upgrading / auditing packages.
    case dependencies
    /// Reading or writing documentation.
    case docs
    /// Editing configuration and infrastructure files.
    case config
    /// Chasing a failure: stack traces, logs, debuggers.
    case debugging
    /// Spawning subagents / delegating work.
    case delegating
    /// Fetching from the web or external docs.
    case research
    /// Nothing more specific could be determined.
    case generic

    /// Short human label, in the interface's language.
    ///
    /// Keyed `topic.*` rather than by the English text, because several of
    /// these are spelled the same as a verb in `ActivitySummary` ("Testing",
    /// "Debugging") and a translation needs them apart: a topic is a noun
    /// ("Hata ayıklama"), the activity line is a verb ("Hata ayıklanıyor").
    public var label: String {
        switch self {
        case .reading:        return String(localized: "topic.reading", defaultValue: "Reading code")
        case .writing:        return String(localized: "topic.writing", defaultValue: "Writing code")
        case .running:        return String(localized: "topic.running", defaultValue: "Running commands")
        case .searching:      return String(localized: "topic.searching", defaultValue: "Searching")
        case .testing:        return String(localized: "topic.testing", defaultValue: "Testing")
        case .versionControl: return String(localized: "topic.versionControl", defaultValue: "Version control")
        case .dependencies:   return String(localized: "topic.dependencies", defaultValue: "Dependencies")
        case .docs:           return String(localized: "topic.docs", defaultValue: "Documentation")
        case .config:         return String(localized: "topic.config", defaultValue: "Configuration")
        case .debugging:      return String(localized: "topic.debugging", defaultValue: "Debugging")
        case .delegating:     return String(localized: "topic.delegating", defaultValue: "Delegating")
        case .research:       return String(localized: "topic.research", defaultValue: "Research")
        case .generic:        return String(localized: "topic.generic", defaultValue: "General")
        }
    }
}
