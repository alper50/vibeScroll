import AppKit
import SwiftUI
import VibeScrollCore

/// Drives the tongue's fidget.
///
/// The same split as `BlinkModel`: how far the tongue is out is the mood and
/// lives in the expression; where the tip is lives here, and is handed to the
/// drawing. The choreography is `TongueMotion`, which is pure and tested — this
/// is only the clock and the animation.
@MainActor
final class TongueModel: ObservableObject {
    static let shared = TongueModel()

    @Published private(set) var pose: TonguePose = .rest

    /// Whether there is a tongue to move right now. The face window asks the
    /// mood; the preview, which has no mood model of its own, answers yes.
    var isShowing: @MainActor () -> Bool = {
        FaceModel.shared.expression.tongue > TongueMotion.visibleAbove
    }

    private var timer: Timer?
    private var pending: [DispatchWorkItem] = []

    private var energy: Double { FaceModel.shared.expression.energy }

    /// Decoration, so skipped rather than slowed — the blink makes the same call.
    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func start() {
        guard timer == nil, !prefersReducedMotion else { return }
        scheduleNext()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending.forEach { $0.cancel() }
        pending.removeAll()
        pose = .rest
    }

    private func scheduleNext() {
        let delay = TongueMotion.interval(energy: energy, jitter: Double.random(in: 0...1))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.fidget() }
        }
    }

    private func fidget() {
        defer { scheduleNext() }
        guard !prefersReducedMotion else { return }

        // No tongue out: settle back to the middle, silently, so the next time
        // it appears it comes out straight rather than already in a corner.
        guard isShowing() else {
            if pose != .rest { pose = .rest }
            return
        }
        // Out of the way of a reaction, like the scheduled blink: two things
        // moving the mouth at once reads as a glitch.
        guard ReactionModel.shared.strength < BlinkRhythm.suppressedAboveReaction else { return }

        let gesture = TongueMotion.gesture(sample: Double.random(in: 0...1))
        let frames = TongueMotion.keyframes(
            for: gesture, from: pose, energy: energy,
            a: Double.random(in: 0...1), b: Double.random(in: 0...1))
        play(frames)
    }

    /// Plays the steps back to back. Eased at both ends so each one reads as a
    /// muscle moving rather than as a value being set.
    private func play(_ frames: [TongueMotion.Keyframe]) {
        var start: TimeInterval = 0
        for frame in frames {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    withAnimation(.easeInOut(duration: frame.duration)) { self?.pose = frame.pose }
                }
            }
            pending.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + start, execute: item)
            start += frame.duration
        }
        // Forget the finished ones so the list does not grow for ever. Safe to
        // clear wholesale: the next gesture is seconds away.
        let cleanup = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pending.removeAll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.05, execute: cleanup)
    }
}
