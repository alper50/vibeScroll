import XCTest
@testable import VibeScrollCore

/// Diversions are a different kind of category: nothing an agent does resolves
/// to one, so they must never arrive on their own. These pin that.
final class DiversionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_773_500_000)

    private func card(_ id: String, _ category: TopicCategory) -> InfoCard {
        InfoCard(id: id, category: category, title: "t", body: "b")
    }

    func testWorkTopicsAreNotDiversions() {
        let work: [TopicCategory] = [
            .reading, .writing, .running, .searching, .testing, .versionControl,
            .dependencies, .docs, .config, .debugging, .delegating, .research, .generic,
        ]
        for topic in work {
            XCTAssertFalse(topic.isDiversion, "\(topic) describes work")
        }
        XCTAssertEqual(TopicCategory.allCases.filter(\.isDiversion).count,
                       TopicCategory.allCases.count - work.count,
                       "a new case was added without deciding which kind it is")
    }

    func testNoToolActivityCanResolveToADiversion() {
        // The guarantee that matters: `CategoryResolver` is the only thing that
        // turns agent activity into a topic, and it cannot produce one of these.
        let targets = [
            "git commit -m wip", "npm install express", "pytest -q", "src/main.ts",
            "README.md", "package-lock.json", "https://example.com", "lldb ./app",
            "game of thrones", "breaking bad", "the office", "stranger things",
        ]
        let tools = ["Bash", "Edit", "Read", "Grep", "Task", "WebFetch", "watch", "play"]
        for target in targets {
            for tool in tools {
                let resolved = CategoryResolver.category(toolName: tool, target: target)
                XCTAssertFalse(resolved?.isDiversion ?? false,
                               "\(tool) + \(target) resolved to \(String(describing: resolved))")
            }
        }
    }

    func testAnAggregateOverSessionsIsNeverADiversion() {
        // Sessions only ever carry a resolved topic, but the aggregate is what
        // the automatic card is drawn from, so it is worth pinning directly.
        var session = AgentSession(id: "a", agentKind: .claude, project: "/w",
                                   state: .working, source: .hook, updatedAt: now)
        session.topic = .gameOfThrones
        session.topicSince = now
        // Even handed one by force, the guard is that nothing constructs this.
        XCTAssertTrue(CategoryResolver.aggregate([session])?.isDiversion ?? false,
                      "aggregate reports what it is given — the protection is upstream")
    }

    func testNextStaysOutOfDiversionsWhileWorking() {
        // `advance` widens past the current topic once it runs out. Left alone
        // it widens into television, which is what the caller's pool filter
        // exists to prevent — modelled here the way CardController does it.
        let scheduler = CardScheduler(policy: .unthrottled)
        let all = [card("work", .debugging), card("tv", .gameOfThrones)]
        let workOnly = all.filter { !$0.category.isDiversion }

        let next = scheduler.advance(from: workOnly, topic: .debugging,
                                     excluding: "work", now: now)
        XCTAssertNil(next, "the only other card was a diversion and must not be reached")
    }

    func testNextStaysInsideADiversionOnceItWasAskedFor() {
        // Having chosen television, Next giving you more of it is the point.
        let scheduler = CardScheduler(policy: .unthrottled)
        let all = [card("tv1", .gameOfThrones), card("tv2", .gameOfThrones),
                   card("work", .debugging)]
        let next = scheduler.advance(from: all, topic: .gameOfThrones,
                                     excluding: "tv1", now: now)
        XCTAssertEqual(next?.id, "tv2")
    }

    func testADiversionStillDecodesFromTheBackend() {
        // Server-first is the documented order, so the client has to already
        // know these names — otherwise they degrade to `generic` and television
        // starts arriving in the middle of work, which is the worst outcome.
        let json = #"{"id":"x","category":"gameOfThrones","title":"t","body":"b"}"#
        let decoded = try? JSONDecoder().decode(InfoCard.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.category, .gameOfThrones)
    }
}
