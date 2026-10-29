import Foundation
import SQLite3

/// Where Claude keeps its data and where this tool keeps saved sign-ins.
struct Locations {
    var claudeData: URL
    var store: URL
    /// Claude Code's own config, which names the account it is signed in with.
    var claudeCodeConfig: URL

    static var standard: Locations {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return Locations(claudeData: support.appendingPathComponent("Claude", isDirectory: true),
                         store: support.appendingPathComponent("Claude Accounts", isDirectory: true),
                         claudeCodeConfig: home.appendingPathComponent(".claude.json"))
    }

    var config: URL { claudeData.appendingPathComponent("config.json") }
    var cookies: URL { claudeData.appendingPathComponent("Cookies") }
    var profiles: URL { store.appendingPathComponent("profiles", isDirectory: true) }
    var names: URL { store.appendingPathComponent("names.json") }
    var details: URL { store.appendingPathComponent("details.json") }
    var backup: URL { store.appendingPathComponent("before-last-switch", isDirectory: true) }
    var log: URL { store.appendingPathComponent("switch.log") }
}

/// The part of Claude's data folder that belongs to the signed-in account. Everything
/// else Claude keeps (sessions, worktrees, settings, connectors) is already filed by
/// account id, so it stays shared and each account finds its own.
enum SignInSet {
    /// The default session's cookie jar and web storage.
    static let items = ["Cookies", "Cookies-journal", "Local Storage", "Session Storage",
                        "IndexedDB", "WebStorage", "Service Worker"]
    /// config.json keys tied to the signed-in account. The token caches are encrypted
    /// with the Mac's "Claude Safe Storage" key, which is the same for every account.
    static let configKeys = ["oauth:tokenCache", "oauth:tokenCacheV2",
                             "lastKnownAccountUuid", "bootSideSessions"]
}

struct Account: Equatable {
    let id: String
    var name: String
    /// When its sign-in was last saved here, which is when it was last switched away
    /// from; nil for the signed-in account before its first switch.
    var savedAt: Date?
}

/// What Claude Code knows about an account. Remembered here once seen, since the files
/// it comes from change with whoever is signed in.
struct AccountDetails: Codable, Equatable {
    var email: String?
    var displayName: String?
    var organization: String?
}

enum AccountsError: LocalizedError {
    case unreadableConfig
    case notSaved(String)

    var errorDescription: String? {
        switch self {
        case .unreadableConfig: return "Claude's config.json could not be read."
        case .notSaved(let name): return "There is no saved sign-in for \(name)."
        }
    }
}

final class AccountStore {
    let loc: Locations
    private let fm = FileManager.default
    private var knownDetails: [String: AccountDetails]?
    private var lookedUpAt: [String: Date] = [:]

    init(_ loc: Locations = .standard) {
        self.loc = loc
    }

    // MARK: Claude's state

    /// The account Claude is signed in as, or nil when it is signed out.
    func currentAccountID() -> String? {
        guard hasSessionCookie(),
              let id = (try? readConfig())?["lastKnownAccountUuid"] as? String,
              !id.isEmpty else { return nil }
        return id
    }

    /// True when Claude's cookie jar holds a claude.ai session. Opened immutable, so it
    /// reads safely while Claude has the file open.
    func hasSessionCookie() -> Bool {
        guard fm.fileExists(atPath: loc.cookies.path),
              let path = loc.cookies.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return false }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2("file:\(path)?immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT count(*) FROM cookies WHERE host_key IN ('.claude.ai', 'claude.ai') AND name = 'sessionKey'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    func readConfig() throws -> [String: Any] {
        guard fm.fileExists(atPath: loc.config.path) else { return [:] }
        let data = try Data(contentsOf: loc.config)
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountsError.unreadableConfig
        }
        return config
    }

    private func writeConfig(_ config: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: loc.config, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: loc.config.path)
    }

    // MARK: Accounts

    /// Saved accounts plus the one Claude is signed in as, by name.
    func accounts() -> [Account] {
        var ids = Set(savedIDs())
        if let current = currentAccountID() { ids.insert(current) }
        return ids.map { Account(id: $0, name: name(of: $0), savedAt: savedAt($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The name given here, else the account's email, else a short id.
    func name(of id: String) -> String {
        readNames()[id] ?? details(of: id).email ?? "Account \(id.prefix(8))"
    }

    func rename(_ id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = readNames()
        names[id] = trimmed.isEmpty || trimmed == details(of: id).email ? nil : trimmed
        try ensureStore()
        let data = try JSONSerialization.data(withJSONObject: names, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: loc.names, options: .atomic)
    }

    /// Deletes an account's saved sign-in from this Mac. The account itself is untouched.
    func forget(_ id: String) throws {
        let dir = profileDir(id)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try rename(id, to: "")
    }

    func details(of id: String) -> AccountDetails {
        var known = knownDetails ?? loadDetails()
        if let details = known[id], details.email != nil { return details }
        // Looking means reading session folders, so a miss is retried once a minute at most.
        if let last = lookedUpAt[id], Date().timeIntervalSince(last) < 60 { return known[id] ?? AccountDetails() }
        lookedUpAt[id] = Date()
        guard let found = findDetails(for: id) else { return known[id] ?? AccountDetails() }
        known[id] = found
        knownDetails = known
        if (try? ensureStore()) != nil,
           let data = try? JSONEncoder.pretty.encode(known) {
            try? data.write(to: loc.details, options: .atomic)
        }
        return found
    }

    private func loadDetails() -> [String: AccountDetails] {
        let loaded = (try? Data(contentsOf: loc.details))
            .flatMap { try? JSONDecoder().decode([String: AccountDetails].self, from: $0) } ?? [:]
        knownDetails = loaded
        return loaded
    }

    /// Claude Code configs name their account: the CLI's own, and the ones Claude keeps
    /// for each Code tab session.
    private func findDetails(for id: String) -> AccountDetails? {
        if let found = details(in: loc.claudeCodeConfig, for: id) { return found }
        let root = loc.claudeData.appendingPathComponent("local-agent-mode-sessions/\(id)", isDirectory: true)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 5000 { break }
            if url.lastPathComponent == "backups" { walker.skipDescendants(); continue }
            if url.lastPathComponent == ".claude.json", let found = details(in: url, for: id) { return found }
        }
        return nil
    }

    private func details(in file: URL, for id: String) -> AccountDetails? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              account["accountUuid"] as? String == id,
              let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        return AccountDetails(email: email,
                              displayName: account["displayName"] as? String,
                              organization: account["organizationName"] as? String)
    }

    private func readNames() -> [String: String] {
        guard let data = try? Data(contentsOf: loc.names),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return names
    }

    private func savedIDs() -> [String] {
        let dirs = (try? fm.contentsOfDirectory(atPath: loc.profiles.path)) ?? []
        return dirs.filter { !$0.hasPrefix(".") && fm.fileExists(atPath: keysFile(in: profileDir($0)).path) }
    }

    private func savedAt(_ id: String) -> Date? {
        (try? fm.attributesOfItem(atPath: keysFile(in: profileDir(id)).path))?[.modificationDate] as? Date
    }

    private func profileDir(_ id: String) -> URL {
        loc.profiles.appendingPathComponent(id, isDirectory: true)
    }

    private func keysFile(in dir: URL) -> URL {
        dir.appendingPathComponent("config-keys.json")
    }

    // MARK: Swapping. Claude must be quit for all of these.

    /// Copies the signed-in account's sign-in into its profile. Returns its id, or nil
    /// when Claude is signed out and there is nothing to save.
    @discardableResult
    func saveCurrent() throws -> String? {
        guard let id = currentAccountID() else { return nil }
        _ = details(of: id)
        let staging = loc.profiles.appendingPathComponent(".saving-\(id)", isDirectory: true)
        try snapshot(into: staging)
        let dest = profileDir(id)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staging, to: dest)
        return id
    }

    /// Keeps a copy of whatever sign-in is in place, signed in or not, until the next switch.
    func backup() throws {
        let staging = loc.store.appendingPathComponent(".saving-backup", isDirectory: true)
        try snapshot(into: staging)
        if fm.fileExists(atPath: loc.backup.path) { try fm.removeItem(at: loc.backup) }
        try fm.moveItem(at: staging, to: loc.backup)
    }

    /// Leaves Claude signed out, so it opens at the sign-in screen. Nothing is sent to
    /// Claude's servers: the account that was signed in keeps its session.
    func clearSignIn() throws {
        try put(from: nil)
    }

    func restore(_ id: String) throws {
        let dir = profileDir(id)
        guard fm.fileExists(atPath: keysFile(in: dir).path) else { throw AccountsError.notSaved(name(of: id)) }
        try put(from: dir)
    }

    func restoreBackup() throws {
        try put(from: loc.backup)
    }

    private func snapshot(into dir: URL) throws {
        try ensureStore()
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        let data = dir.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for item in SignInSet.items {
            let source = loc.claudeData.appendingPathComponent(item)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: data.appendingPathComponent(item))
            }
        }
        let config = try readConfig()
        var keys: [String: Any] = [:]
        for key in SignInSet.configKeys { keys[key] = config[key] }
        try JSONSerialization.data(withJSONObject: keys, options: [.prettyPrinted, .withoutEscapingSlashes])
            .write(to: keysFile(in: dir))
    }

    /// Replaces the sign-in in Claude's data folder with a profile's, or with nothing.
    private func put(from dir: URL?) throws {
        var config = try readConfig()
        let saved: [String: Any]
        if let dir {
            let data = try Data(contentsOf: keysFile(in: dir))
            saved = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } else {
            saved = [:]
        }
        for item in SignInSet.items {
            let target = loc.claudeData.appendingPathComponent(item)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            if let source = dir?.appendingPathComponent("data/\(item)"), fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: target)
            }
        }
        for key in SignInSet.configKeys { config[key] = saved[key] }
        try writeConfig(config)
    }

    private func ensureStore() throws {
        try fm.createDirectory(at: loc.profiles, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: loc.store.path)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
