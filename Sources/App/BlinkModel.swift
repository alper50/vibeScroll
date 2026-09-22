import AppKit
import SwiftUI
import VibeScrollCore

/// Drives the blink.
///
/// Deliberately separate from `FaceModel`. The expression is the mood, and a
/// blink is not a change of mood — routing it through the published expression
/// would republish it every few seconds and redraw everything observing it, to
/// say nothing new. So the lids live here and are multiplied into the drawing.
///
/// The rhythm itself is `BlinkRhythm`, which is pure and tested; this is only
/// the clock and the animation.
@MainActor
final class BlinkModel: ObservableObject {
    /// Shared because two other models need to reach it: a startle fires a
    /// blink of its own, and a scheduled blink has to know a reaction is
    /// playing so it can stay out of the way. There has only ever been one
    /// face window, so this was already a singleton in everything but name.
    static let shared = BlinkModel()

    /// 0 open … 1 fully shut.
    @Published private(set) var amount: Double = 0

    private var timer: Timer?
    private var pending: [DispatchWorkItem] = []

    /// Read at scheduling time rather than bound: `.onChange(of:)` changed
    /// signature in macOS 14 and this needs to work on 13, and a blink only
    /// needs to know the energy at the moment it is scheduled anyway.
    private var energy: Double { FaceModel.shared.expression.energy }

    /// Blinking is decoration, so it is skipped entirely rather than slowed —
    /// the same call `TypewriterModel` makes about its reveal.
    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func start() {
        guard timer == nil, !prefersReducedMotion else { return }
        scheduleNext()
    }

    /// Called when the panel goes away. A face nobody can see has no reason to
    /// keep a timer alive.
    func stop() {
        timer?.invalidate()
        timer = nil
        cancelPending()
        amount = 0
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        pending.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPending() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }

    /// A blink that answers to nothing — no schedule, no suppression.
    ///
    /// Fired by a startle, where the blink is *part* of the reaction rather
    /// than an interruption of it. The lid multiplies into the eye at drawing
    /// time, so the wide-eyed impulse riding over it still lands: the eye shuts
    /// for a moment and opens wider than it started, which is what a startle
    /// actually looks like.
    func blinkNow() {
        guard !prefersReducedMotion, timer != nil else { return }
        cancelPending()
        play(energy: energy)
    }

    private func scheduleNext() {
        let delay = BlinkRhythm.interval(energy: energy, jitter: Double.random(in: 0...1))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.blink() }
        }
    }

    private func blink() {
        guard !prefersReducedMotion else { return }
        defer { scheduleNext() }

        // Asleep: skip the blink but keep the timer, so the face wakes by
        // itself. Stopping the schedule instead would need something to notice
        // the energy coming back, and a timer firing every eight seconds to do
        // nothing is cheaper than the machinery that would take.
        guard !BlinkRhythm.sleeps(atEnergy: energy) else {
            if amount != 0 { amount = 0 }
            return
        }
        // Out of the way of a reaction that is already playing. Only the
        // scheduled blink defers; `blinkNow` is the startle's own.
        guard ReactionModel.shared.strength < BlinkRhythm.suppressedAboveReaction else {
            return
        }

        let energy = self.energy
        play(energy: energy)

        // Every so often, twice. It is the blinks varying rather than only the
        // gaps between them that stops the rhythm reading as a metronome.
        if BlinkRhythm.isDouble(sample: Double.random(in: 0...1)) {
            let gap = BlinkRhythm.duration(energy: energy) + BlinkRhythm.doubleGap
            schedule(after: gap) { [weak self] in self?.play(energy: energy) }
        }
    }

    /// One lid down and up. The two halves are deliberately unequal — a lid
    /// drops faster than it lifts, and equal halves read as a shutter.
    private func play(energy: Double) {
        let closing = BlinkRhythm.closeDuration(energy: energy)
        let opening = BlinkRhythm.openDuration(energy: energy)

        withAnimation(.easeIn(duration: closing)) { amount = 1 }
        schedule(after: closing) { [weak self] in
            withAnimation(.easeOut(duration: opening)) { self?.amount = 0 }
        }
    }
}
