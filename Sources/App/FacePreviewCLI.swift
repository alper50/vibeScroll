import AppKit
import SwiftUI
import VibeScrollCore

/// `vibescroll face` — a window for looking at the face.
///
/// The numbers being right does not make the drawing good, and that cannot be
/// judged from a test. This exists so the geometry can be tuned by eye without
/// Xcode, and so the scenarios below can be checked visually: each one runs
/// real `FaceMood` input through the real pipeline, so what appears here is
/// exactly what the panel would show.
enum FacePreviewCLI {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "vibeScroll \u{2014} face preview"
        window.contentView = NSHostingView(rootView: FacePreview())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

private struct FacePreview: View {
    @State private var expression = FaceMood.base(for: .working)
    @StateObject private var blink = BlinkModel()
    @ObservedObject private var reaction = ReactionModel.shared

    private var reacted: FaceExpression {
        guard let impulse = reaction.impulse else { return expression }
        return expression.applying(impulse, strength: reaction.strength)
    }
    @State private var scenario = "Working"

    private let now = Date()

    var body: some View {
        VStack(spacing: 0) {
            FaceView(expression: reacted, blink: blink.amount)
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
                .animation(.easeInOut(duration: 0.35), value: expression)
                .onAppear { blink.start() }

            Divider()

            Form {
                Section("Scenario \u{2014} real FaceMood output") {
                    // Two columns of buttons rather than a picker: comparing
                    // them means clicking back and forth quickly.
                    ForEach(Self.scenarios, id: \.name) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            if scenario == item.name {
                                Text("shown").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Apply") {
                                scenario = item.name
                                expression = FaceMood.expression(for: item.inputs(now), now: now)
                            }
                        }
                    }
                }

                Section("Reactions") {
                    HStack {
                        ForEach(FaceReaction.allCases, id: \.self) { reaction in
                            Button(String(describing: reaction).capitalized) {
                                ReactionModel.shared.fire(reaction)
                            }
                        }
                        Spacer()
                    }
                }

                Section {
                    slider("Brow", $expression.browAngle, -1...1)
                    slider("Eyes", $expression.eyeOpenness, 0...1)
                    slider("Mouth", $expression.mouthCurve, -1...1)
                    slider("Strain", $expression.strain, 0...1)
                    slider("Energy", $expression.energy, 0...1)
                    slider("Brow skew", $expression.browSkew, -1...1)
                    slider("Mouth open", $expression.mouthOpen, 0...1)
                    slider("Tongue", $expression.tongue, 0...1)
                } header: {
                    Text("Parameters")
                } footer: {
                    Text("Energy drives the blink rate. The preview reads it from the panel's own face model, so the pace here is the pace you will get.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func slider(
        _ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>
    ) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: "%+.2f", value.wrappedValue))
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    // MARK: - Scenarios

    private struct Scenario {
        let name: String
        let inputs: (Date) -> FaceInputs
    }

    private static func session(
        _ state: AgentState, id: String = "preview",
        topicAge: TimeInterval = 0, sessionAge: TimeInterval = 0
    ) -> (Date) -> AgentSession {
        { now in
            AgentSession(id: id, agentKind: .claude, state: state, source: .hook,
                         updatedAt: now,
                         createdAt: now.addingTimeInterval(-sessionAge),
                         topicSince: now.addingTimeInterval(-topicAge))
        }
    }

    private static func weekly(percent: Int, resetsIn: TimeInterval) -> (Date) -> QuotaSnapshot {
        { now in
            QuotaSnapshot(
                provider: "claude", displayName: "Claude",
                windows: [QuotaWindow(kind: "weekly_all", percentUsed: percent,
                                      severity: .normal,
                                      resetsAt: now.addingTimeInterval(resetsIn),
                                      isActive: true)],
                checkedAt: now)
        }
    }

    private static func session5h(percent: Int, resetsIn: TimeInterval) -> (Date) -> QuotaSnapshot {
        { now in
            QuotaSnapshot(
                provider: "claude", displayName: "Claude",
                windows: [QuotaWindow(kind: "session", percentUsed: percent,
                                      severity: .normal,
                                      resetsAt: now.addingTimeInterval(resetsIn),
                                      isActive: true)],
                checkedAt: now)
        }
    }

    private static let scenarios: [Scenario] = [
        Scenario(name: "Nothing running") { _ in FaceInputs() },
        Scenario(name: "Working") { FaceInputs(sessions: [session(.working)($0)]) },
        Scenario(name: "Waiting for you") { FaceInputs(sessions: [session(.waiting)($0)]) },
        Scenario(name: "Finished") { FaceInputs(sessions: [session(.done)($0)]) },
        Scenario(name: "Idle") { FaceInputs(sessions: [session(.idle)($0)]) },
        Scenario(name: "Over budget (85% spent, 67% of week gone)") {
            FaceInputs(sessions: [session(.working)($0)],
                       quota: weekly(percent: 85, resetsIn: 54.9 * 3600)($0))
        },
        Scenario(name: "Stuck on one topic for 45 min") {
            FaceInputs(sessions: [session(.working, topicAge: 45 * 60)($0)])
        },
        Scenario(name: "Six hours in") {
            FaceInputs(sessions: [session(.working, sessionAge: 6 * 3600)($0)])
        },
        Scenario(name: "Three rate limits this hour") {
            FaceInputs(sessions: [session(.working)($0)],
                       rateLimits: [$0.addingTimeInterval(-60),
                                    $0.addingTimeInterval(-900),
                                    $0.addingTimeInterval(-1800)])
        },
        Scenario(name: "Four agents at once") { now in
            FaceInputs(sessions: (0..<4).map { i in
                AgentSession(id: "a\(i)", agentKind: .claude, state: .working,
                             source: .hook, updatedAt: now, createdAt: now, topicSince: now)
            })
        },
        Scenario(name: "Burning tokens fast") {
            FaceInputs(sessions: [session(.working)($0)], tokensPerMinute: 4000)
        },
        Scenario(name: "One waiting while another works") { now in
            FaceInputs(sessions: [session(.working, id: "a")(now),
                                  session(.waiting, id: "b")(now)])
        },
        Scenario(name: "Five-hour window burned early") { now in
            FaceInputs(sessions: [session(.working)(now)],
                       quota: session5h(percent: 80, resetsIn: 3 * 3600)(now))
        },
        Scenario(name: "All of it at once") { now in
            FaceInputs(sessions: [session(.working, topicAge: 3 * 3600, sessionAge: 12 * 3600)(now)],
                       quota: weekly(percent: 100, resetsIn: 160 * 3600)(now),
                       rateLimits: (0..<5).map { now.addingTimeInterval(-Double($0) * 300) },
                       tokensPerMinute: 5000)
        },
    ]
}
