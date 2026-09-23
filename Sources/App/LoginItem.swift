import Foundation
import ServiceManagement

/// Registers the app to start at login.
///
/// The task queue makes this load-bearing rather than a convenience: a window
/// that resets at 03:00 is only useful if something is running to notice. Hooks
/// still queue to disk while the app is closed, so nothing is *lost* either way
/// — but nothing is run either.
///
/// `SMAppService` needs a real bundle (see `scripts/build-app.sh`) and reports
/// `.requiresApproval` when the user has switched the item off in System
/// Settings. That is a distinct state from "off", and is surfaced rather than
/// silently retried: re-registering cannot override the user's own choice.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    enum State: Equatable {
        case on
        case off
        /// Registered, but the user disabled it in System Settings > Login Items.
        case blockedByUser
        case unavailable(String)

        var isOn: Bool { self == .on }
    }

    @Published private(set) var state: State = .off

    private init() { refresh() }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:          state = .on
        case .requiresApproval: state = .blockedByUser
        case .notRegistered:    state = .off
        case .notFound:         state = .unavailable(String(localized: "Login item not found for this build."))
        @unknown default:       state = .off
        }
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            // Unsigned or relocated bundles fail here. Reporting beats a toggle
            // that silently springs back with no explanation.
            state = .unavailable(error.localizedDescription)
        }
    }
}
