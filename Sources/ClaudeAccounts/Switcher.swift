import AppKit
import Darwin

/// The installed Claude app: finding its processes, quitting it and opening it again.
struct ClaudeApp {
    static let bundleID = "com.anthropic.claudefordesktop"

    let appURL: URL

    static var installed: ClaudeApp? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(ClaudeApp.init)
    }

    private var contents: String {
        Self.realPath(appURL.appendingPathComponent("Contents")) + "/"
    }

    private var mainExecutable: String {
        Bundle(url: appURL)?.executableURL.map(Self.realPath) ?? contents + "MacOS/Claude"
    }

    /// The path the kernel reports for processes. resolvingSymlinksInPath would drop a
    /// leading /private, which proc_pidpath keeps.
    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    var isRunning: Bool { !mainPIDs().isEmpty }

    func mainPIDs() -> [pid_t] {
        processes().filter { $0.path == mainExecutable }.map(\.pid)
    }

    /// Everything running from inside the app bundle, except the Chrome native host,
    /// which Chrome starts and owns.
    func bundleProcesses() -> [(pid: pid_t, path: String)] {
        processes().filter { $0.path.hasPrefix(contents) && !$0.path.hasSuffix("/chrome-native-host") }
    }

    private func processes() -> [(pid: pid_t, path: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var result: [(pid: pid_t, path: String)] = []
        for pid in pids.prefix(Int(max(found, 0))) where pid > 0 {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                result.append((pid, String(cString: buffer)))
            }
        }
        return result
    }

    /// Asks Claude to quit the normal way and waits for it, its helpers and any pending
    /// update install to finish. Claude may ask the person to confirm first: `onSlow` is
    /// called when it hasn't quit after a few seconds. False when it didn't quit or the
    /// task was canceled.
    func quit(log: (String) -> Void, onSlow: () async -> Void = {}) async -> Bool {
        let pids = mainPIDs()
        guard !pids.isEmpty else { return true }
        log("asking Claude to quit")
        for pid in pids { NSRunningApplication(processIdentifier: pid)?.terminate() }
        let start = Date()
        var slow = false
        while !mainPIDs().isEmpty {
            if Task.isCancelled { log("canceled while Claude was quitting"); return false }
            if Date().timeIntervalSince(start) > 180 { log("Claude did not quit"); return false }
            if !slow, Date().timeIntervalSince(start) > 4 {
                slow = true
                await onSlow()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let helpersDeadline = Date().addingTimeInterval(45)
        while !bundleProcesses().isEmpty, Date() < helpersDeadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !bundleProcesses().isEmpty {
            log("still running after quit: " + bundleProcesses().map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))
        }
        log("Claude quit")
        return mainPIDs().isEmpty
    }

    func open() async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
}

enum SwitchTarget: Equatable {
    case account(String)
    /// Claude opens signed out, ready for another account to sign in.
    case signIn
}

/// The steps of a switch, in order.
enum SwitchStep: Int, Comparable {
    case quit, save, signIn, open, done

    static func < (a: SwitchStep, b: SwitchStep) -> Bool { a.rawValue < b.rawValue }
}

enum SwitchError: LocalizedError {
    case canceled
    case claudeDidNotQuit
    case claudeReopened
    case failed(Error, restored: Bool)

    var errorDescription: String? {
        switch self {
        case .canceled:
            return "Switch canceled. Nothing changed."
        case .claudeDidNotQuit:
            return "Claude didn't quit, so nothing changed. If Claude asked whether to quit, choose Quit and try again."
        case .claudeReopened:
            return "Claude opened again on its own, probably finishing an update, so nothing changed. Try again in a moment."
        case .failed(let error, let restored):
            return error.localizedDescription + (restored
                ? " Claude was put back the way it was."
                : " A copy of the previous sign-in is in ~/Library/Application Support/Claude Accounts/before-last-switch.")
        }
    }
}

/// Quits Claude, files away the signed-in account's sign-in, puts the target's in place
/// and opens Claude again.
struct Switcher {
    let store: AccountStore
    let claude: ClaudeApp
    /// Called as each step starts; `slow` once Claude is taking a while to quit.
    var progress: @MainActor (_ step: SwitchStep, _ slow: Bool) -> Void = { _, _ in }

    func run(_ target: SwitchTarget) async throws {
        log("switch to " + describe(target))
        await progress(.quit, false)
        guard await claude.quit(log: log, onSlow: { await progress(.quit, true) }) else {
            throw Task.isCancelled ? SwitchError.canceled : SwitchError.claudeDidNotQuit
        }
        if Task.isCancelled {
            log("canceled after Claude quit, opening it unchanged")
            try? await claude.open()
            throw SwitchError.canceled
        }
        guard !claude.isRunning else { throw SwitchError.claudeReopened }
        do {
            try store.backup()
            await progress(.save, false)
            if let saved = try store.saveCurrent() { log("saved \(saved)") }
            await progress(.signIn, false)
            switch target {
            case .account(let id): try store.restore(id)
            case .signIn: try store.clearSignIn()
            }
            log("sign-in in place for " + describe(target))
        } catch {
            log("failed: \(error.localizedDescription)")
            let restored = (try? store.restoreBackup()) != nil
            try? await claude.open()
            throw SwitchError.failed(error, restored: restored)
        }
        await progress(.open, false)
        try await claude.open()
        log("opened Claude")
        await progress(.done, false)
    }

    private func describe(_ target: SwitchTarget) -> String {
        switch target {
        case .account(let id): return id
        case .signIn: return "sign-in screen"
        }
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = Data("\(stamp) \(line)\n".utf8)
        let url = store.loc.log
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: store.loc.store, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? entry.write(to: url)
        }
    }
}
