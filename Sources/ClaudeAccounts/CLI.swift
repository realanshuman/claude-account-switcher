import AppKit

/// `Claude Accounts.app/Contents/MacOS/ClaudeAccounts <command>`: the same switching as
/// the menu, for scripts and launchers.
enum CLI {
    static let usage = """
    usage: ClaudeAccounts <command> [options]

      list                 saved accounts; * marks the one Claude is signed in as
      status               whether Claude is running and which account it is on
      switch <account>     switch Claude to an account (name, id or id prefix)
      add                  open Claude at the sign-in screen to add an account
      rename <account> <name>
      remove <account>

    options:
      --here               run in this process. Without it, switch and add hand off to a
                           separate process, so they survive Claude quitting even when
                           started from a terminal inside Claude.
      --data-dir <path>    Claude's data folder, with .claude.json next to it (testing)
      --store <path>       where saved sign-ins live (testing)
      --claude-app <path>  the app to quit and open (testing)
    """

    static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments
        var loc = Locations.standard
        var appURL: URL?
        var here = false

        func value(for flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let value = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return value
        }
        if let path = value(for: "--data-dir") {
            loc.claudeData = URL(fileURLWithPath: path, isDirectory: true)
            loc.claudeCodeConfig = loc.claudeData.deletingLastPathComponent().appendingPathComponent(".claude.json")
        }
        if let path = value(for: "--store") { loc.store = URL(fileURLWithPath: path, isDirectory: true) }
        if let path = value(for: "--claude-app") { appURL = URL(fileURLWithPath: path, isDirectory: true) }
        if let i = args.firstIndex(of: "--here") { here = true; args.remove(at: i) }

        let store = AccountStore(loc)
        guard let command = args.first else {
            print(usage)
            return 2
        }

        func account(_ query: String?) -> String? {
            guard let query, !query.isEmpty else { return nil }
            let accounts = store.accounts()
            if let match = accounts.first(where: { $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
                return match.id
            }
            let prefixed = accounts.filter { $0.id.hasPrefix(query.lowercased()) }
            return prefixed.count == 1 ? prefixed[0].id : nil
        }

        switch command {
        case "list":
            let current = store.currentAccountID()
            for a in store.accounts() {
                let saved = a.savedAt.map { "saved " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "not saved yet"
                print("\(a.id == current ? "*" : " ") \(a.name)  \(a.id)  (\(saved))")
            }
            if current == nil { print("Claude is signed out") }
            return 0

        case "status":
            guard let claude = appURL.map(ClaudeApp.init) ?? ClaudeApp.installed else {
                print("Claude isn't installed")
                return 1
            }
            let pids = claude.mainPIDs()
            print(pids.isEmpty ? "Claude is not running" : "Claude is running (pid \(pids.map(String.init).joined(separator: ", ")), \(claude.bundleProcesses().count) processes)")
            print(store.currentAccountID().map { "Signed in as \(store.name(of: $0))" } ?? "Signed out")
            return 0

        case "switch", "add":
            let target: SwitchTarget
            if command == "add" {
                target = .signIn
            } else if let id = account(args.dropFirst().first) {
                if id == store.currentAccountID() {
                    print("Claude is already signed in as \(store.name(of: id))")
                    return 0
                }
                target = .account(id)
            } else {
                printError("no saved account matches \"\(args.dropFirst().first ?? "")\"")
                return 1
            }
            guard let claude = appURL.map(ClaudeApp.init) ?? ClaudeApp.installed else {
                printError("Claude isn't installed")
                return 1
            }
            if !here, handOff(arguments) {
                print("Switching in the background. Progress: \(loc.log.path)")
                return 0
            }
            let labels: [SwitchStep: String] = [.quit: "quitting Claude", .save: "saving the current sign-in",
                                                .signIn: "putting the new sign-in in place", .open: "opening Claude",
                                                .done: "done"]
            do {
                try await Switcher(store: store, claude: claude) { step, slow in
                    print(slow ? "waiting for Claude to quit (it may be asking you to confirm)" : labels[step] ?? "")
                }.run(target)
                return 0
            } catch {
                printError(error.localizedDescription)
                return 1
            }

        case "rename":
            guard let id = account(args.dropFirst().first), args.count >= 3 else {
                printError("usage: rename <account> <name>")
                return 1
            }
            do { try store.rename(id, to: args.dropFirst(2).joined(separator: " ")) } catch {
                printError(error.localizedDescription)
                return 1
            }
            return 0

        case "remove":
            guard let id = account(args.dropFirst().first), id != store.currentAccountID() else {
                printError("pick a saved account Claude isn't signed in as")
                return 1
            }
            do { try store.forget(id) } catch {
                printError(error.localizedDescription)
                return 1
            }
            return 0

        case "probe-panel":
            await PanelProbe.run()
            return 0

        case "render-preview":
            guard let dir = args.dropFirst().first else {
                printError("usage: render-preview <folder>")
                return 1
            }
            await MainActor.run { Previews.render(to: URL(fileURLWithPath: dir, isDirectory: true)) }
            return 0

        default:
            print(usage)
            return 2
        }
    }

    /// Starts this command again as a fresh app process through Launch Services, so it is
    /// not a child of the terminal (and maybe of Claude). False when not running from the app bundle.
    private static func handOff(_ arguments: [String]) -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-g", bundle.path, "--args"] + arguments + ["--here"]
        do {
            try open.run()
            open.waitUntilExit()
            return open.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}
