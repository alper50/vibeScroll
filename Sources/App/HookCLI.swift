import Foundation
import VibeScrollCore

/// CLI helper invoked by agent hooks: `vibescroll hook --agent claude`.
///
/// Runs on the agent's critical path, so it does exactly two things — decode
/// and forward — and always exits 0.
enum HookCLI {
    static func run(arguments: [String]) -> Never {
        let now = Date()
        let parsed = HookArguments.parse(arguments)
        let kind = parsed.agent.flatMap(AgentKind.init(rawValue:)) ?? .claude

        // Explicit flags win (used by the opencode plugin, the Pi extension and
        // the run wrapper); otherwise fall back to the agent's hook payload on
        // stdin, decoded with that agent's field convention.
        var event = parsed.makeEvent(now: now)
            ?? HookPayload.event(forAgent: kind, stdin: FileHandle.standardInput.readDataToEndOfFile(), now: now)

        // Tag the event with the terminal we're running in, so a click on a
        // card's session row can focus that exact window/tab later.
        let terminal = TerminalInfo.capture()
        event?.terminalProgram = terminal.program
        event?.terminalTTY = terminal.tty
        event?.terminalFocusURL = terminal.focusURL
        event?.hostBundleID = terminal.hostBundleID

        guard let event else {
            FileHandle.standardError.write(Data(
                "usage: vibescroll hook --event <name> --session <id> [--project <path>] [--agent <kind>] [--message <text>]\n         or pipe an agent hook JSON payload on stdin\n".utf8
            ))
            // Fail OPEN: a monitoring hook must never block the agent. Some
            // agents scan ~/.claude / ~/.cursor and feed us a payload we can't
            // decode; a non-zero exit there is read as a Stop-gate "keep going"
            // (re-prompt loop) or a PreToolUse "deny". Exit 0 = do nothing, safely.
            exit(0)
        }

        EventSender.send(event, socketPath: VibeScrollPaths.socketPath, queueDir: VibeScrollPaths.queueDir)
        exit(0)
    }
}
