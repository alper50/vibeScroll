import Foundation

/// Single binary, three roles:
/// - `vibescroll hook ...` runs the lightweight CLI helper invoked by agent hooks.
/// - `vibescroll run -- <cmd>` wraps any command as a tracked session.
/// - no arguments launches the menu bar app.
///
/// One binary means the hook command a user installs can never drift from the
/// app version that reads it.
@main
struct VibeScrollMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "hook":
            HookCLI.run(arguments: Array(args.dropFirst()))
        case "run":
            RunCLI.run(arguments: Array(args.dropFirst()))
        default:
            VibeScrollApp.main()
        }
    }
}
