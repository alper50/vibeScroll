import Foundation

/// Where a rate-limit window stands relative to the clock.
///
/// Shared because two very different features ask the same question: the task
/// queue needs it to decide whether spending more is responsible, and the face
/// needs it to decide whether to look worried. Duplicating the arithmetic would
/// let the gate and the expression drift into disagreeing about the same week.
public enum QuotaPace {

    /// Window identifiers meaning "the rolling few-hour allowance".
    public static let sessionKinds: Set<String> = ["session", "five_hour"]

    /// …and the weekly ones. Per-model pools are included so a plan reporting
    /// them is read from whichever is tightest, rather than from a combined
    /// figure that hides the one about to run out.
    public static let weeklyKinds: Set<String> = [
        "weekly_all", "seven_day", "weekly_opus", "seven_day_opus",
        "weekly_sonnet", "seven_day_sonnet",
    ]

    /// Nominal length of a window.
    ///
    /// The endpoint reports when a window *ends* but never when it began, so
    /// this is the one piece the arithmetic cannot read and has to know. An
    /// unrecognised kind returns `nil` and is skipped rather than guessed: a
    /// wrong duration would silently distort every judgement made from it.
    public static func duration(forKind kind: String) -> TimeInterval? {
        if sessionKinds.contains(kind) { return 5 * 3600 }
        if weeklyKinds.contains(kind) { return 7 * 24 * 3600 }
        return nil
    }

    /// How far through its window we are, 0...1, or `nil` when the window has
    /// no reset time or an unknown length.
    public static func elapsedFraction(_ window: QuotaWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt,
              let duration = duration(forKind: window.kind), duration > 0
        else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / duration, 0), 1)
    }

    /// The tightest window of a group — the one that will actually stop you.
    public static func tightest(_ windows: [QuotaWindow], in kinds: Set<String>) -> QuotaWindow? {
        windows.filter { kinds.contains($0.kind) }.max { $0.percentUsed < $1.percentUsed }
    }

    /// How far spending has run ahead of the clock, as a fraction.
    ///
    /// Positive means more of the budget is gone than of the window: 85% spent
    /// with 67% of the week elapsed gives `0.18`. Negative means there is room.
    /// `nil` when the window cannot be placed on its own timeline.
    ///
    /// This is the number both callers actually want. A percentage on its own
    /// says nothing — 85% is alarming on Tuesday and fine on Sunday night.
    public static func overspend(_ window: QuotaWindow, now: Date) -> Double? {
        guard let elapsed = elapsedFraction(window, now: now) else { return nil }
        return Double(window.percentUsed) / 100 - elapsed
    }
}
