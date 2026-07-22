import AppKit
import Foundation
import WispKit

// No arguments (or a Finder process-serial argument) → run as the menu bar
// app. Anything else → headless CLI (snapshot, ask, doctor, key, memory…).
let cliArguments = Array(CommandLine.arguments.dropFirst())

if cliArguments.isEmpty || cliArguments[0].hasPrefix("-psn") {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
} else {
    let exitCode = await CLIRunner.run(arguments: cliArguments)
    exit(exitCode)
}
