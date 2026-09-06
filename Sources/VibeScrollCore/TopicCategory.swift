import Foundation

/// What the agent is currently doing, normalised across every supported agent.
///
/// This is the join key between the event pipeline and the content backend:
/// the daemon resolves a topic, then asks the backend for a card in that topic.
/// Adding a case here means adding content for it server-side — keep the set
/// small and behavioural ("what is happening"), not technological ("which
/// language"), so a card stays relevant regardless of stack.
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

    /// Stable slug used in backend URLs and cache filenames.
    public var slug: String { rawValue }

    /// Short human label. The backend may override this per locale; this is the
    /// offline fallback so a cached card always has something to render.
    public var fallbackLabel: String {
        switch self {
        case .reading:        return "Reading code"
        case .writing:        return "Writing code"
        case .running:        return "Running commands"
        case .searching:      return "Searching"
        case .testing:        return "Testing"
        case .versionControl: return "Version control"
        case .dependencies:   return "Dependencies"
        case .docs:           return "Documentation"
        case .config:         return "Configuration"
        case .debugging:      return "Debugging"
        case .delegating:     return "Delegating"
        case .research:       return "Research"
        case .generic:        return "General"
        }
    }
}
