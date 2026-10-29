import AppKit
import ServiceManagement
import SwiftUI

struct AccountRow: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let initials: String
    let tint: Int
    let isCurrent: Bool
}

/// What the panel shows, and everything it can do.
@MainActor
final class AccountsModel: ObservableObject {
    struct Progress: Equatable {
        var target: String
        var initials: String
        var tint: Int
        /// The account being saved on the way out, nil when Claude was signed out.
        var leaving: String?
        var adding: Bool
        var step: SwitchStep = .quit
        var slowQuit = false
    }

    static let addRow = "add"
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)

    @Published private(set) var rows: [AccountRow] = []
    @Published private(set) var claudeInstalled = true
    @Published private(set) var claudeRunning = false
    @Published private(set) var signedIn = false
    @Published private(set) var progress: Progress?
    @Published private(set) var openAtLogin = false
    @Published var error: String?
    /// The row showing its switch confirmation: an account id or `addRow`.
    @Published var expanded: String?
    @Published var renaming: String?
    @Published var removing: String?
    /// Snapshots only: the row drawn as hovered.
    var previewHover: String?

    let store: AccountStore
    var onFinished: () -> Void = {}
    var onNeedsAttention: () -> Void = {}
    private var task: Task<Void, Never>?
    private var steps: [(SwitchStep, Bool)] = []
    private var showingSteps = false

    init(store: AccountStore) {
        self.store = store
    }

    var currentName: String? { rows.first(where: \.isCurrent)?.name }
    var canCancel: Bool { task != nil && progress?.step == .quit }

    // MARK: State

    func refresh() {
        guard progress == nil else { return }
        let claude = ClaudeApp.installed
        let current = store.currentAccountID()
        let rows = store.accounts().map { row(for: $0, current: current) }
        let running = claude?.isRunning ?? false
        if claudeInstalled != (claude != nil) { claudeInstalled = claude != nil }
        if claudeRunning != running { withAnimation(Self.spring) { claudeRunning = running } }
        if signedIn != (current != nil) { withAnimation(Self.spring) { signedIn = current != nil } }
        if self.rows != rows { withAnimation(Self.spring) { self.rows = rows } }
    }

    /// Separate from refresh, which runs every couple of seconds while the panel is open.
    func refreshLoginItem() {
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func row(for account: Account, current: String?) -> AccountRow {
        let details = store.details(of: account.id)
        var parts: [String] = []
        if let email = details.email, email.caseInsensitiveCompare(account.name) != .orderedSame {
            parts.append(email)
        }
        if let org = details.organization, !org.hasSuffix("'s Organization"), !org.contains("@") {
            parts.append(org)
        }
        if account.id != current, let saved = account.savedAt {
            parts.append("Last used " + Self.relative(saved))
        }
        if parts.isEmpty { parts.append(account.id == current ? "Signed in" : "Saved") }
        return AccountRow(id: account.id, name: account.name, detail: parts.joined(separator: " · "),
                          initials: Self.initials(account.name), tint: Self.tint(account.id),
                          isCurrent: account.id == current)
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: "@", maxSplits: 1)
        if parts.count == 2, let a = parts[0].first, let b = parts[1].first {
            return (String(a) + String(b)).uppercased()
        }
        let words = name.split(whereSeparator: { " ._-".contains($0) })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    static func tint(_ id: String) -> Int {
        id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % palette.count
    }

    static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .brown]

    private static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Rows

    func tap(_ id: String) {
        guard progress == nil, id != rows.first(where: \.isCurrent)?.id else { return }
        withAnimation(Self.spring) {
            renaming = nil
            removing = nil
            expanded = expanded == id ? nil : id
        }
    }

    func beginRename(_ id: String) {
        withAnimation(Self.spring) {
            expanded = nil
            removing = nil
            renaming = id
        }
    }

    func commitRename(_ id: String, to name: String) {
        do { try store.rename(id, to: name) } catch { show(error) }
        renaming = nil
        refresh()
    }

    func cancelRename() {
        renaming = nil
    }

    func beginRemove(_ id: String) {
        withAnimation(Self.spring) {
            expanded = nil
            renaming = nil
            removing = id
        }
    }

    func cancelRemove() {
        withAnimation(Self.spring) { removing = nil }
    }

    func confirmRemove(_ id: String) {
        do { try store.forget(id) } catch { show(error) }
        withAnimation(Self.spring) { removing = nil }
        refresh()
    }

    /// Esc steps back out of a confirmation or rename first. False when there was
    /// nothing to back out of, so the panel can close.
    func escape() -> Bool {
        guard expanded != nil || renaming != nil || removing != nil || error != nil else { return false }
        withAnimation(Self.spring) {
            expanded = nil
            renaming = nil
            removing = nil
            error = nil
        }
        return true
    }

    /// Back to the resting state, without animation, for when the panel closes.
    func reset() {
        expanded = nil
        renaming = nil
        removing = nil
        error = nil
    }

    func dismissError() {
        withAnimation(Self.spring) { error = nil }
    }

    // MARK: Switching

    func switchTo(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        start(.account(id), Progress(target: row.name, initials: row.initials, tint: row.tint,
                                     leaving: currentName, adding: false))
    }

    func addAccount() {
        start(.signIn, Progress(target: "another account", initials: "", tint: 0,
                                leaving: currentName, adding: true))
    }

    func cancelSwitch() {
        task?.cancel()
    }

    private func start(_ target: SwitchTarget, _ shown: Progress) {
        guard task == nil, let claude = ClaudeApp.installed else { return }
        let switcher = Switcher(store: AccountStore(store.loc), claude: claude) { [weak self] step, slow in
            self?.queue(step, slow: slow)
        }
        withAnimation(Self.spring) {
            expanded = nil
            renaming = nil
            removing = nil
            error = nil
            progress = shown
        }
        task = Task { @MainActor in
            do {
                try await switcher.run(target)
                await stepsShown()
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                onFinished()
                try? await Task.sleep(nanoseconds: 250_000_000)
                progress = nil
            } catch SwitchError.canceled {
                steps.removeAll()
                withAnimation(Self.spring) { progress = nil }
            } catch {
                steps.removeAll()
                withAnimation(Self.spring) {
                    progress = nil
                    self.error = error.localizedDescription
                }
                onNeedsAttention()
            }
            task = nil
            refresh()
        }
    }

    /// The work behind most steps takes milliseconds. Each step stays on screen long
    /// enough to read, so the list ticks through in order instead of flashing.
    private func queue(_ step: SwitchStep, slow: Bool) {
        steps.append((step, slow))
        guard !showingSteps else { return }
        showingSteps = true
        Task { @MainActor in
            while !steps.isEmpty {
                let (step, slow) = steps.removeFirst()
                guard progress != nil else { continue }
                withAnimation(.easeInOut(duration: 0.22)) {
                    progress?.step = step
                    progress?.slowQuit = slow
                }
                try? await Task.sleep(nanoseconds: 320_000_000)
            }
            showingSteps = false
        }
    }

    private func stepsShown() async {
        while showingSteps || !steps.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: App

    func openClaude() {
        Task { try? await ClaudeApp.installed?.open() }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show(error)
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showSavedSignIns() {
        try? FileManager.default.createDirectory(at: store.loc.store, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(store.loc.store)
    }

    private func show(_ error: Error) {
        withAnimation(Self.spring) { self.error = error.localizedDescription }
    }

    // MARK: Snapshots

    /// A model with fixed content, for rendering the panel without touching Claude.
    static func preview(rows: [AccountRow], running: Bool = true, signedIn: Bool = true,
                        progress: Progress? = nil, error: String? = nil, expanded: String? = nil,
                        removing: String? = nil, hover: String? = nil) -> AccountsModel {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-accounts-preview")
        let model = AccountsModel(store: AccountStore(Locations(claudeData: temp, store: temp,
                                                                claudeCodeConfig: temp)))
        model.rows = rows
        model.claudeRunning = running
        model.signedIn = signedIn
        model.progress = progress
        model.error = error
        model.expanded = expanded
        model.removing = removing
        model.previewHover = hover
        return model
    }
}
