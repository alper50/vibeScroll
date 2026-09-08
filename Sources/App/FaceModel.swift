import Foundation
import VibeScrollCore

/// Keeps the face's expression current.
///
/// Two things feed it, and they arrive very differently. Sessions and rate
/// limits are pushed in by the daemon as they happen; thrash and fatigue grow
/// with nothing but the clock — a session circling one topic for forty minutes
/// emits no events at all, and `AppDaemon.prune` only publishes when something
/// changed. So this keeps a slow timer of its own rather than relying on
/// activity to notice the passage of time.
@MainActor
final class FaceModel: ObservableObject {
    static let shared = FaceModel()

    @Published private(set) var expression: FaceExpression = FaceMood.base(for: nil)
    /// Why it looks like that. The expression says something is off; this says
    /// what, which is the difference between a gauge and an ornament.
    @Published private(set) var reason: FaceMood.Reason = .steady(nil)

    /// Slow on purpose. Thrash and fatigue move over minutes, so re-reading
    /// them twice a minute is already finer than the signal, and this app has
    /// to be cheap enough to leave running all day.
    private static let tick: TimeInterval = 30

    private var sessions: [AgentSession] = []
    private var rateLimits: [Date] = []
    private var timer: Timer?

    private let policy = FaceMood.Policy()

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { _ in
            Task { @MainActor in FaceModel.shared.recompute() }
        }
        recompute()
    }

    /// Called by the daemon whenever its published session list changes.
    func update(sessions: [AgentSession]) {
        self.sessions = sessions
        recompute()
    }

    /// Recorded rather than only announced: three rate limits in an hour is
    /// something the face should carry, not just three notifications you have
    /// already dismissed.
    func noteRateLimit(at date: Date = Date()) {
        rateLimits.append(date)
        recompute()
    }

    private func recompute() {
        let now = Date()
        // Dropped here rather than in `FaceMood`, so the pure side stays a
        // function of what it is given and this stays the only thing holding
        // history.
        rateLimits.removeAll { now.timeIntervalSince($0) > policy.rateLimitWindow }

        let inputs = FaceInputs(sessions: sessions, quota: UsageProbe.shared.snapshot,
                                rateLimits: rateLimits)
        let next = FaceMood.expression(for: inputs, policy: policy, now: now)
        if next != expression { expression = next }

        let why = FaceMood.dominantReason(for: inputs, policy: policy, now: now)
        if why != reason { reason = why }
    }
}
