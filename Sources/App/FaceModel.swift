import Foundation
import SwiftUI
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

    /// Token totals over time, which is the only history this app keeps.
    /// Nothing else needs a rate, and `SessionStore` deliberately forgets.
    private var tokenSamples: [(at: Date, total: Int)] = []
    private static let rateWindow: TimeInterval = 3 * 60
    /// Samples no closer together than this. The daemon refreshes several times
    /// a second and three minutes of that would be thousands of entries to say
    /// what a dozen already say.
    private static let sampleGap: TimeInterval = 10

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

    /// When somebody last touched the face.
    private var lastInteraction: Date?

    /// The face was clicked or dragged.
    ///
    /// Recomputes straight away rather than waiting for the next tick: the
    /// whole point is that the eyes open *now*, and a thirty-second timer is
    /// not an answer to a click. The mood then keeps it awake for
    /// `drowsyAfter` before it starts drifting off again, so it does not shut
    /// the moment the reaction finishes.
    func wake(at date: Date = Date()) {
        lastInteraction = date
        // An explicit spring, which overrides the slow ease the expression
        // normally animates under. That 0.8s is right for a mood drifting and
        // wrong for an answer to a click — a face that takes most of a second
        // to notice it was poked is the dull part of this.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { recompute() }
    }

    /// How many rate limits are still inside the window. The moment card says
    /// the count, and this is the one place that keeps it — the same list the
    /// face's own fatigue reads.
    var rateLimitsThisHour: Int {
        let now = Date()
        return rateLimits.filter { now.timeIntervalSince($0) <= policy.rateLimitWindow }.count
    }

    /// Tokens burned per minute across everything running.
    ///
    /// A session that is pruned takes its tokens with it, so the running total
    /// can fall. That is bookkeeping, not a negative burn rate, and the floor
    /// below is what keeps a tidy-up from reading as the work stopping.
    private func tokensPerMinute(now: Date) -> Double {
        let total = sessions.compactMap(\.tokens).reduce(0, +)
        if tokenSamples.last.map({ now.timeIntervalSince($0.at) >= Self.sampleGap }) ?? true {
            tokenSamples.append((now, total))
        }
        tokenSamples.removeAll { now.timeIntervalSince($0.at) > Self.rateWindow }

        guard let oldest = tokenSamples.first else { return 0 }
        let elapsed = now.timeIntervalSince(oldest.at)
        // Too short a baseline turns one ordinary turn into a spike.
        guard elapsed >= 45 else { return 0 }
        return Double(max(0, total - oldest.total)) / (elapsed / 60)
    }

    private func recompute() {
        let now = Date()
        // Dropped here rather than in `FaceMood`, so the pure side stays a
        // function of what it is given and this stays the only thing holding
        // history.
        rateLimits.removeAll { now.timeIntervalSince($0) > policy.rateLimitWindow }

        let inputs = FaceInputs(
            sessions: sessions, quota: UsageProbe.shared.snapshot,
            rateLimits: rateLimits,
            tokensPerMinute: tokensPerMinute(now: now),
            lastInteraction: lastInteraction)
        let next = FaceMood.expression(for: inputs, policy: policy, now: now)
        if next != expression { expression = next }

        let why = FaceMood.dominantReason(for: inputs, policy: policy, now: now)
        if why != reason { reason = why }
    }
}
