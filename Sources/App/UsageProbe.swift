import AppKit
import Foundation
import VibeScrollCore

/// Polls Claude's quota so the app can warn before the wall instead of after it.
///
/// This is the one part of vibeScroll that talks to a provider directly, and it
/// is worth being explicit about the trade it makes. The endpoint
/// (`api.anthropic.com/api/oauth/usage`) is not a documented public API; it is
/// what Claude Code itself calls, reached with the OAuth token Claude Code
/// stores in the Keychain. Consequences the user is opting into:
///
/// - Reading the token shells out to `security`, which can raise a Keychain
///   prompt the first time.
/// - The request identifies itself as Claude Code, because the endpoint expects
///   that client.
/// - Anthropic can change or withdraw any of this without notice, at which
///   point the probe goes quiet.
///
/// Everything here is read-only: the token is never written back, refreshed or
/// stored by this app, and a failure degrades to "no quota information" rather
/// than to an error the user has to dismiss.
@MainActor
final class UsageProbe: ObservableObject {
    static let shared = UsageProbe()

    @Published private(set) var snapshot: QuotaSnapshot?
    /// Set when the last poll failed, for the Settings caption only.
    @Published private(set) var lastError: String?

    /// Quota moves slowly; five minutes is frequent enough to warn in time and
    /// infrequent enough to be invisible.
    private static let pollInterval: TimeInterval = 300
    private var timer: Timer?

    /// Whether the probe runs at all. Off by default: it reaches out to a
    /// provider and touches the Keychain, so it is the user's call to make.
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    private static let enabledKey = "vibescroll.quotaProbeEnabled"

    /// Remembers whether we were already exhausted, so the alert fires on the
    /// transition into exhaustion rather than on every poll while it lasts.
    private var wasExhausted = false

    func start() {
        guard enabled, timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in UsageProbe.shared.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        snapshot = nil
        lastError = nil
        wasExhausted = false
    }

    func poll() {
        guard enabled else { return }
        Task { [weak self] in
            let result = await Self.fetch()
            await MainActor.run { self?.apply(result) }
        }
    }

    /// When the five-hour window we last saw was due to roll over. A window
    /// whose reset time has moved on by most of a window is a new one.
    private var lastSessionReset: Date?

    /// Edge-triggered, like the exhausted sound above: the point is the moment
    /// the window rolls over, which is the moment there is quota to spend
    /// again. Silent on the first reading — a window seen once is not a window
    /// that just renewed, and saying so at launch would be a lie every time.
    private func noteWindowRollover(in snapshot: QuotaSnapshot) {
        guard let window = QuotaPace.tightest(snapshot.windows, in: QuotaPace.sessionKinds),
              let resetsAt = window.resetsAt
        else { return }
        defer { lastSessionReset = resetsAt }
        guard let previous = lastSessionReset,
              QuotaPace.isNewWindow(resetsAt: resetsAt, after: previous, kind: window.kind)
        else { return }
        CardController.shared.raise(.windowRenewed)
    }

    private func apply(_ result: Result<QuotaSnapshot, ProbeError>) {
        switch result {
        case .success(let snapshot):
            noteWindowRollover(in: snapshot)
            self.snapshot = snapshot
            lastError = nil
            // Edge-triggered: the sound marks the moment you run out, not the
            // state of being out.
            if snapshot.isExhausted, !wasExhausted {
                SoundSettings.shared.play(.quota)
                NotificationManager.shared.notify(
                    title: "Claude quota exhausted",
                    body: snapshot.tightest.map(Self.resetLine) ?? "Waiting for the window to reset")
            }
            wasExhausted = snapshot.isExhausted
        case .failure(let error):
            lastError = error.message
        }
    }

    private static func resetLine(_ window: QuotaWindow) -> String {
        guard let resetsAt = window.resetsAt else { return "\(window.label) limit reached" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(window.label) resets \(formatter.localizedString(for: resetsAt, relativeTo: Date()))"
    }

    // MARK: - Fetching

    struct ProbeError: Error {
        let message: String
    }

    private nonisolated static func fetch() async -> Result<QuotaSnapshot, ProbeError> {
        guard let token = accessToken() else {
            return .failure(ProbeError(message: "No Claude Code sign-in found."))
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(claudeCodeVersion())", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard status == 200 else {
                // 401 is the common one: the stored token expired because the
                // CLI has not run in a while.
                return .failure(ProbeError(message: status == 401
                    ? "Claude sign-in expired — run Claude Code once to refresh it."
                    : "Quota check failed (HTTP \(status))."))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let snapshot = ClaudeUsageParser.parse(json, now: Date()) else {
                return .failure(ProbeError(message: "Quota response could not be read."))
            }
            return .success(snapshot)
        } catch {
            return .failure(ProbeError(message: error.localizedDescription))
        }
    }

    /// Reported so the endpoint sees a current client. Read from the installed
    /// extension rather than hardcoded, because a pinned old version is exactly
    /// the kind of thing that starts being rejected silently.
    private nonisolated static func claudeCodeVersion() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let extensions = home.appendingPathComponent(".vscode/extensions")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: extensions.path) {
            let versions = entries
                .filter { $0.hasPrefix("anthropic.claude-code-") }
                .compactMap { $0.dropFirst("anthropic.claude-code-".count).split(separator: "-").first }
                .map(String.init)
                .sorted()
            if let latest = versions.last { return latest }
        }
        return "2.1.0"
    }

    /// Claude Code's OAuth access token: Keychain first (current versions),
    /// then the legacy credentials file.
    private nonisolated static func accessToken() -> String? {
        if let text = keychainPassword(service: "Claude Code-credentials"),
           let token = parseCredentials(text) {
            return token
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json").path
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           let token = parseCredentials(text) {
            return token
        }
        return nil
    }

    private nonisolated static func parseCredentials(_ raw: String) -> String? {
        let text = decodeHexIfNeeded(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    private nonisolated static func keychainPassword(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        // Read before waiting: a large value can fill the pipe buffer and
        // deadlock a process that is waited on first.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty ?? true) ? nil : output
    }

    /// `security … -w` hex-encodes values containing newlines, so a JSON
    /// payload can arrive as one long hex string.
    private nonisolated static func decodeHexIfNeeded(_ text: String) -> String {
        guard !text.hasPrefix("{"), text.count % 2 == 0, text.count > 2,
              text.allSatisfy({ $0.isHexDigit }) else { return text }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return text }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
