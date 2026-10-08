import Foundation

/// Decides when an alert sound plays when several arrive close together.
///
/// Several agents finishing at once would overlap into noise, so sounds inside
/// a short window are merged. Merged, not dropped: the earlier rule let the
/// first sound through and threw away everything else for two seconds, so an
/// agent waiting on you right after another finished made no sound at all —
/// across a busy afternoon, that read as sounds simply going missing.
///
/// Now a request inside the window is dropped only when something at least as
/// important has already been heard (or is about to be). A more important one
/// is held to the end of the window and played then; only the most important
/// of a burst is kept, so the end of a burst is one sound, not a queue.
public struct SoundGate: Sendable {
    public enum Decision: Equatable, Sendable {
        case playNow
        /// Hold it and call `firePending(now:)` at this time.
        case playAt(Date)
        /// Covered by a sound already heard or already scheduled.
        case drop
    }

    public let window: TimeInterval
    private var lastPlayed: (priority: Int, at: Date)?
    public private(set) var pending: Int?

    public init(window: TimeInterval) {
        self.window = window
    }

    /// `priority`: higher is more important. Someone blocked on you outranks
    /// a quota warning, which outranks a turn finishing.
    public mutating func request(priority: Int, now: Date) -> Decision {
        guard let last = lastPlayed, now.timeIntervalSince(last.at) < window else {
            // Outside any window. A pending one would already have fired;
            // anything left over is stale and this sound supersedes it.
            pending = nil
            lastPlayed = (priority, now)
            return .playNow
        }
        let covered = max(last.priority, pending ?? Int.min)
        guard priority > covered else { return .drop }
        pending = priority
        return .playAt(last.at.addingTimeInterval(window))
    }

    /// The held sound, when its time comes: returns its priority and counts it
    /// as played. `nil` when nothing is held.
    public mutating func firePending(now: Date) -> Int? {
        guard let priority = pending else { return nil }
        pending = nil
        lastPlayed = (priority, now)
        return priority
    }
}
