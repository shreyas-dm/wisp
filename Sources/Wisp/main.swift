import Foundation
import WispKit

// Entry point. CLI subcommands run headless; no arguments launches the app.
// (App bootstrap lands with the UI module.)
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "version" {
    print("wisp 0.1.0-dev")
    exit(0)
}
print("wisp: app bootstrap not wired yet — try `wisp version`")
