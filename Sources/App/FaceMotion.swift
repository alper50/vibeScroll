import Foundation

/// The face's three clocks — blink, tongue, idle glances — started and stopped
/// together.
///
/// Started and stopped by `CardController` rather than by the face's view,
/// which is not told when its window is ordered out. They run while the
/// floating face is on screen and not otherwise — the notch style draws no
/// face at all: a face nobody can see has no reason to keep a timer alive, and
/// that is the whole reason these are affordable — they sleep for seconds and
/// animate for milliseconds.
@MainActor
enum FaceMotion {
    private(set) static var running = false

    static func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            BlinkModel.shared.start()
            TongueModel.shared.start()
            GazeModel.shared.startIdleMotion()
        } else {
            BlinkModel.shared.stop()
            TongueModel.shared.stop()
            GazeModel.shared.stopIdleMotion()
        }
    }
}
