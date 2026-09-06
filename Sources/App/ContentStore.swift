import Foundation
import VibeScrollCore

/// Fetches the teaching catalogue from the backend and keeps it on disk.
///
/// Offline is the normal case, not an error path: agents run on planes and in
/// locked-down networks. So the store always serves from an in-memory copy
/// hydrated from disk at launch, and a fetch only ever *replaces* that copy on
/// success. A failed refresh is silent — the user keeps seeing yesterday's
/// cards rather than an empty surface.
@MainActor
final class ContentStore: ObservableObject {
    static let shared = ContentStore()

    /// Cards grouped by topic, ready for the scheduler to pick from.
    @Published private(set) var byCategory: [TopicCategory: [InfoCard]] = [:]
    @Published private(set) var version: String = ""
    @Published private(set) var lastRefreshAt: Date?
    /// Last failure, surfaced in Settings only. Never blocks card display.
    @Published private(set) var lastError: String?

    private static let baseURLKey = "vibescroll.backendURL"
    private static let defaultBaseURL = "http://127.0.0.1:8787"
    private static let refreshInterval: TimeInterval = 6 * 3600

    private var refreshTimer: Timer?
    private var inFlight = false

    /// Backend origin. Overridable so a self-hosted or staging instance needs no
    /// rebuild — the app is useless without content, so this must be swappable.
    var baseURL: URL {
        let raw = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        return URL(string: raw) ?? URL(string: Self.defaultBaseURL)!
    }

    func setBaseURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.baseURLKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.baseURLKey)
        }
        // A different origin invalidates the version we were negotiating with.
        version = ""
        Task { await refresh(force: true) }
    }

    func start() {
        loadFromDisk()
        Task { await refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in await ContentStore.shared.refresh() }
        }
    }

    func cards(for category: TopicCategory) -> [InfoCard] {
        byCategory[category] ?? []
    }

    /// Every card, in a stable order. Manual navigation spills across
    /// categories, so it needs the whole pool — sorted by id rather than
    /// dictionary order so the traversal can't reshuffle between calls.
    var allCards: [InfoCard] {
        byCategory.values.flatMap { $0 }.sorted { $0.id < $1.id }
    }

    /// Total card count, for the Settings status line.
    var count: Int { byCategory.values.reduce(0) { $0 + $1.count } }

    // MARK: - Networking

    /// Pulls the catalogue. `force` ignores the stored version so the server
    /// can't answer 304 — used after the origin changes.
    func refresh(force: Bool = false) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/catalog"))
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The catalogue is content-addressed by version; an unchanged one costs
        // a 304 instead of re-sending every card.
        if !force, !version.isEmpty {
            request.setValue("\"\(version)\"", forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            if code == 304 {
                lastRefreshAt = Date()
                lastError = nil
                return
            }
            guard (200..<300).contains(code) else {
                lastError = "Backend returned HTTP \(code)"
                return
            }
            let bundle = try JSONDecoder().decode(CardBundle.self, from: data)
            apply(bundle)
            writeToDisk(data)
            lastRefreshAt = Date()
            lastError = nil
        } catch {
            // Keep whatever we already had; only report.
            lastError = error.localizedDescription
        }
    }

    private func apply(_ bundle: CardBundle) {
        version = bundle.version
        byCategory = Dictionary(grouping: bundle.cards, by: \.category)
    }

    // MARK: - Disk cache

    private var cacheURL: URL {
        URL(fileURLWithPath: VibeScrollPaths.cacheDir).appendingPathComponent("catalog.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let bundle = try? JSONDecoder().decode(CardBundle.self, from: data)
        else { return }
        apply(bundle)
    }

    private func writeToDisk(_ data: Data) {
        try? FileManager.default.createDirectory(
            atPath: VibeScrollPaths.cacheDir, withIntermediateDirectories: true)
        // Atomic so a crash mid-write can't leave a truncated cache that then
        // fails to decode on the next launch.
        try? data.write(to: cacheURL, options: .atomic)
    }
}
