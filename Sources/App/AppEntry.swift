import Foundation

/// Single binary, three roles:
/// - `vibescroll hook ...` runs the lightweight CLI helper invoked by agent hooks.
/// - `vibescroll run -- <cmd>` wraps any command as a tracked session.
/// - `vibescroll face` opens a window for tuning the face by eye.
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
        case "face":
            // Development affordance: the drawing cannot be judged from a test.
            FacePreviewCLI.run()
        default:
            VibeScrollApp.main()
        }
    }
}
