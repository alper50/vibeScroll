import AppKit
import VibeScrollCore

/// Which style the face is shown in, and whether this Mac can show the notch.
///
/// Owns the preference and the one fact about the hardware the choice depends
/// on. Everything that decides *what* to show stays in `CardController`; this
/// only answers *where*, and tells the controller when that answer changes.
@MainActor
final class DisplayStyleStore: ObservableObject {
    static let shared = DisplayStyleStore()

    private static let preferredKey = "vibescroll.displayStyle"
    private static let hidesInFullscreenKey = "vibescroll.notchHidesInFullscreen"

    /// `nil` until somebody chooses. Kept distinct from "floating" so the
    /// question can still be asked the first time a notched display appears.
    @Published var preferred: DisplayStyle? =
        UserDefaults.standard.string(forKey: preferredKey).flatMap(DisplayStyle.init(rawValue:))
    {
        didSet {
            UserDefaults.standard.set(preferred?.rawValue, forKey: Self.preferredKey)
            if oldValue != preferred { styleChanged() }
        }
    }

    /// Off by default: the floating face has always stayed over full-screen
    /// apps, and switching styles should not quietly change that.
    @Published var hidesInFullscreen: Bool =
        UserDefaults.standard.bool(forKey: hidesInFullscreenKey)
    {
        didSet {
            UserDefaults.standard.set(hidesInFullscreen, forKey: Self.hidesInFullscreenKey)
            NotchWindowController.shared.applySpaceBehaviour()
        }
    }

    /// The notched display, when one is connected.
    @Published private(set) var notch: NotchScreen?

    var notchAvailable: Bool { notch != nil }

    var effective: DisplayStyle {
        DisplayStyle.effective(preferred: preferred, notchAvailable: notchAvailable)
    }

    var shouldAsk: Bool {
        DisplayStyle.shouldAsk(preferred: preferred, notchAvailable: notchAvailable)
    }

    private var observer: NSObjectProtocol?

    func start() {
        notch = NotchScreen.current()
        // Lid closed, lid opened, a display plugged in: the one moment the
        // answer to "is there a notch" can change. Nothing polls.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DisplayStyleStore.shared.screensChanged() }
        }
    }

    private func screensChanged() {
        let next = NotchScreen.current()
        guard next != notch else { return }
        let before = effective
        notch = next
        NotchWindowController.shared.relayout()
        if effective != before { styleChanged() }
    }

    private func styleChanged() {
        CardController.shared.displayStyleChanged()
    }
}

/// Where the notch is, and how big.
struct NotchScreen: Equatable {
    let displayID: CGDirectDisplayID
    /// The whole screen, in global coordinates.
    let frame: CGRect
    let notchWidth: Double
    let notchHeight: Double
    /// The notch's centre line, in global x. The camera sits at the middle of
    /// the built-in display, but measured rather than assumed.
    let notchMidX: Double

    /// The first screen with a camera housing. `safeAreaInsets.top` is only
    /// non-zero on a notched display; the two auxiliary areas are the menu bar
    /// either side of it, so the notch is what they leave between them.
    static func current() -> NotchScreen? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { continue }
            var width = NotchLayout.fallbackNotchWidth
            var midX = Double(screen.frame.midX)
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let measured = Double(screen.frame.width - left.width - right.width)
                if measured > 40 {
                    width = measured
                    midX = Double(screen.frame.minX + left.width) + measured / 2
                }
            }
            return NotchScreen(displayID: CGDirectDisplayID(number.uint32Value),
                               frame: screen.frame,
                               notchWidth: width,
                               notchHeight: Double(screen.safeAreaInsets.top),
                               notchMidX: midX)
        }
        return nil
    }
}
