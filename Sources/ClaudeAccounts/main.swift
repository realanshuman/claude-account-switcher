import AppKit

// No arguments: the menu bar app. With a command: the CLI (see CLI.usage).
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

if arguments.isEmpty {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
} else {
    Task {
        exit(await CLI.run(Array(arguments)))
    }
    RunLoop.main.run()
}
