import AppKit
import Foundation
import VibeScrollCore

/// Owns the two alert sounds and plays them.
///
/// Sounds are played directly with `NSSound` rather than attached to the
/// notification. That trade was made deliberately: a directly played sound
/// always reaches the user, needs no notification permission, and leaves the
/// choice entirely in this app's hands — at the cost of ignoring Focus modes.
/// Because of that choice `NotificationManager` sends its banners *silent*;
/// attaching a sound there too would double every alert.
@MainActor
final class SoundSettings: ObservableObject {
    static let shared = SoundSettings()

    /// Which event a sound belongs to. Kept separate because they mean
    /// different things: finishing is information, needing input is a block.
    enum Event: String, CaseIterable {
        case done, waiting, quota

        var title: String {
            switch self {
            case .done: return String(localized: "When an agent finishes")
            case .waiting: return String(localized: "When an agent needs input")
            case .quota: return String(localized: "When you run out of quota")
            }
        }

        /// Distinct defaults so the three are tellable apart without looking:
        /// all bundled, but three different cuts of the recording rather than
        /// one sound for everything. Applies only until the user picks
        /// something — a stored choice always wins.
        var fallback: SoundSelection {
            switch self {
            case .done: return .bundled("Fart 1")
            case .waiting: return .bundled("Fart 3")
            case .quota: return .bundled("Fart 4")
            }
        }

        var defaultsKey: String { "vibescroll.sound.\(rawValue)" }

        /// For merging a burst: someone blocked on you outranks a quota
        /// warning, which outranks a turn finishing.
        var priority: Int {
            switch self {
            case .done: return 1
            case .quota: return 2
            case .waiting: return 3
            }
        }
    }

    @Published private(set) var selections: [Event: SoundSelection] = [:]

    /// System sounds this Mac can actually load. Filtered once at startup so a
    /// name macOS has dropped never appears in the picker as a dead option.
    let availableSystemNames: [String]
    /// Bundled sounds this build can actually load, filtered the same way: a
    /// resource missing from the bundle must not appear as a dead option.
    let availableBundledNames: [String]

    /// Several agents finishing at once would otherwise overlap into noise,
    /// so a burst is merged into one sound — see `SoundGate`. The window is
    /// short: a held sound is at most a second late, and only when another
    /// has just played.
    private var gate = SoundGate(window: 1)
    private var pendingWork: DispatchWorkItem?

    private init() {
        availableSystemNames = SoundSelection.systemNames.filter { NSSound(named: $0) != nil }
        availableBundledNames = SoundSelection.bundledNames.filter { NSSound(named: $0) != nil }
        var loaded: [Event: SoundSelection] = [:]
        for event in Event.allCases {
            let stored = UserDefaults.standard.string(forKey: event.defaultsKey)
            loaded[event] = SoundSelection.decode(stored) ?? event.fallback
        }
        selections = loaded
    }

    func selection(for event: Event) -> SoundSelection {
        selections[event] ?? event.fallback
    }

    func set(_ selection: SoundSelection, for event: Event) {
        selections[event] = selection
        UserDefaults.standard.set(selection.encoded, forKey: event.defaultsKey)
    }

    // MARK: - Playing

    /// Plays the sound for `event`, subject to the burst throttle.
    func play(_ event: Event) {
        switch gate.request(priority: event.priority, now: Date()) {
        case .playNow:
            pendingWork?.cancel()
            pendingWork = nil
            preview(selection(for: event))
        case .playAt(let date):
            // One timer however many join the burst: the gate keeps only the
            // most important, and that is what is read when it fires.
            guard pendingWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingWork = nil
                    guard let priority = self.gate.firePending(now: Date()),
                          let held = Event.allCases.first(where: { $0.priority == priority })
                    else { return }
                    self.preview(self.selection(for: held))
                }
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow),
                                          execute: work)
        case .drop:
            break
        }
    }

    /// Plays a selection immediately, bypassing the throttle. Used by the
    /// Settings preview button, which must respond to every click.
    func preview(_ selection: SoundSelection) {
        guard let sound = makeSound(selection) else { return }
        sound.stop()      // restart rather than overlap when clicked repeatedly
        sound.play()
    }

    private func makeSound(_ selection: SoundSelection) -> NSSound? {
        switch selection {
        case .silent:
            return nil
        case .system(let name), .bundled(let name):
            // `NSSound(named:)` searches the app bundle's Resources before the
            // system sound folders, so one call resolves both — verified, not
            // assumed.
            return NSSound(named: name)
        case .custom(let url):
            // byReference: false loads the data now, so playback doesn't stutter
            // on first use and a file removed later still plays this session.
            return NSSound(contentsOf: url, byReference: false)
        }
    }

    // MARK: - Custom files

    /// Where picked sounds are copied. Owning the file means the setting cannot
    /// break because the user moved or deleted the original.
    private static var soundsDirectory: URL {
        URL(fileURLWithPath: VibeScrollPaths.baseDir).appendingPathComponent("sounds")
    }

    enum ImportError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return String(localized: "\(name) could not be played as a sound.")
            }
        }
    }

    /// Validates, copies and selects a user-picked file.
    ///
    /// Validation happens before the copy: a file that `NSSound` cannot load
    /// would otherwise be stored as the user's choice and then silently play
    /// nothing, which reads as the feature being broken.
    func importSound(from source: URL, for event: Event) throws {
        guard NSSound(contentsOf: source, byReference: false) != nil else {
            throw ImportError.unreadable(source.lastPathComponent)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.soundsDirectory, withIntermediateDirectories: true)

        let ext = source.pathExtension.isEmpty ? "aiff" : source.pathExtension
        let destination = Self.soundsDirectory
            .appendingPathComponent("\(event.rawValue).\(ext)")
        // Replacing the previous file for this event keeps the directory to at
        // most one file per event instead of accumulating every past pick.
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
        removeStaleCustomFiles(for: event, keeping: destination)

        set(.custom(destination), for: event)
    }

    /// Drops earlier picks for this event that used a different extension.
    private func removeStaleCustomFiles(for event: Event, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.soundsDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries
        where entry.deletingPathExtension().lastPathComponent == event.rawValue
            && entry != keep {
            try? fm.removeItem(at: entry)
        }
    }
}
