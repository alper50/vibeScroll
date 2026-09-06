import AppKit
import Foundation
import VibeScrollCore

/// Drives a `TypewriterReveal` by publishing elapsed time.
///
/// The reveal itself is pure; this is only the clock. It ticks at 30 fps and
/// computes the character count from elapsed time rather than firing one timer
/// per character — at 90 characters a second that would be 90 view updates a
/// second, and this is an ambient app that has to stay cheap. The timer stops
/// itself on completion, so a settled card costs nothing at all.
@MainActor
final class TypewriterModel: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0

    private var timer: Timer?
    private var startedAt: Date?
    private var duration: TimeInterval = 0

    private static let frameInterval: TimeInterval = 1.0 / 30.0

    /// True when the system asks for reduced motion. A typing effect is
    /// decorative, so it is skipped entirely rather than merely shortened.
    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Restarts the animation for a newly presented card.
    func run(duration: TimeInterval) {
        stop()
        self.duration = duration
        guard duration > 0, !prefersReducedMotion else {
            elapsed = max(duration, 0)   // show the whole card at once
            return
        }
        elapsed = 0
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Jumps to the end — used when the reader clicks the card because they
    /// read faster than the animation writes.
    func finish() {
        elapsed = duration
        stop()
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= duration { finish() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
    }
}
