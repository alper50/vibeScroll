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
    /// 0 open … 1 fully shut.
    @Published private(set) var amount: Double = 0

    private var timer: Timer?
    private var closing: DispatchWorkItem?

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
        closing?.cancel()
        closing = nil
        amount = 0
    }

    private func scheduleNext() {
        let delay = BlinkRhythm.interval(energy: energy, jitter: Double.random(in: 0...1))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.blink() }
        }
    }

    private func blink() {
        guard !prefersReducedMotion else { return }

        // Asleep: skip the blink but keep the timer, so the face wakes by
        // itself. Stopping the schedule instead would need something to notice
        // the energy coming back, and a timer firing every eight seconds to do
        // nothing is cheaper than the machinery that would take.
        guard !BlinkRhythm.sleeps(atEnergy: energy) else {
            if amount != 0 { amount = 0 }
            scheduleNext()
            return
        }

        let duration = BlinkRhythm.duration(energy: energy)

        withAnimation(.easeIn(duration: duration / 2)) { amount = 1 }
        let open = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: duration / 2)) { self?.amount = 0 }
        }
        closing = open
        DispatchQueue.main.asyncAfter(deadline: .now() + duration / 2, execute: open)

        scheduleNext()
    }
}
