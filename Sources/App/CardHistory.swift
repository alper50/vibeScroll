import Foundation
import VibeScrollCore

/// Which cards have been read and when, kept across launches.
///
/// Without it every relaunch started the catalogue over: the scheduler
/// remembered nothing, so the same first card came up again — text read ten
/// minutes earlier. A few hundred ids and timestamps at most, so the user
/// defaults are a fine home; the cache directory is for things that can be
/// thrown away, and this cannot without the same card coming back.
enum CardHistory {
    private static let historyKey = "vibescroll.cardsShown"
    private static let seedKey = "vibescroll.cardOrderSeed"

    /// The saved history, with anything too old to matter dropped.
    static func load(now: Date = Date()) -> [String: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        let history = stored.mapValues { Date(timeIntervalSince1970: $0) }
        return CardScheduler.pruned(history, now: now)
    }

    static func save(_ history: [String: Date]) {
        UserDefaults.standard.set(history.mapValues { $0.timeIntervalSince1970 },
                                  forKey: historyKey)
    }

    /// This install's card order: drawn once, then kept, so the order unseen
    /// cards arrive in is stable from launch to launch.
    static var orderSeed: UInt64 {
        if let stored = UserDefaults.standard.object(forKey: seedKey) as? Int {
            return UInt64(bitPattern: Int64(stored))
        }
        let seed = UInt64.random(in: .min ... .max)
        UserDefaults.standard.set(Int(Int64(bitPattern: seed)), forKey: seedKey)
        return seed
    }
}
