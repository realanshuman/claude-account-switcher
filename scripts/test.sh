#!/bin/zsh
# End-to-end test against a fake Claude app and a fake data folder, so the real Claude
# is never quit or touched. Usage: scripts/test.sh [work-dir]   (run ./build.sh first)
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -x /Library/Developer/CommandLineTools/usr/bin/swift ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

T=${1:-$(mktemp -d)}
rm -rf "$T"; mkdir -p "$T"
D="$T/Claude"; S="$T/store"; FAKE="$T/FakeClaude.app"
BIN="$PWD/build/Claude Accounts.app/Contents/MacOS/ClaudeAccounts"
A=aaaaaaaa-1111-4111-8111-111111111111
B=bbbbbbbb-2222-4222-8222-222222222222
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
cli() { "$BIN" --data-dir "$D" --store "$S" --claude-app "$FAKE" "$@"; }
cookie() { sqlite3 "$D/Cookies" "select encrypted_value from cookies where name='sessionKey'" 2>/dev/null || echo none; }
key() {  # a config.json value by dotted path; plutil can't read JSON with null in it
  node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const v = process.argv[2].split(".").reduce((o, k) => o == null ? undefined : o[k], c);
    console.log(v === undefined ? "absent" : v)' "$D/config.json" "$1"
}
running() { pgrep -f "$FAKE/Contents/MacOS/FakeClaude" >/dev/null; }
wait_for() { for _ in {1..80}; do eval "$1" && return 0; sleep 0.25; done; return 1; }

# A fake Claude: logs launches and, like Claude, writes to its storage while quitting.
mkdir -p "$FAKE/Contents/MacOS"
cat > "$FAKE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.fakeclaude</string>
<key>CFBundleExecutable</key><string>FakeClaude</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cat > "$T/fake.swift" <<'SWIFT'
import AppKit
final class Fake: NSObject, NSApplicationDelegate {
    let home = Bundle.main.bundleURL.deletingLastPathComponent()
    var data: URL { home.appendingPathComponent("Claude") }
    func account() -> String {
        let config = try? JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("config.json")))
        return (config as? [String: Any])?["lastKnownAccountUuid"] as? String ?? "none"
    }
    func log(_ line: String) {
        let url = home.appendingPathComponent("events.log")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func applicationDidFinishLaunching(_ n: Notification) { log("launched as \(account())") }
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let leveldb = self.data.appendingPathComponent("Local Storage/leveldb")
            try? FileManager.default.createDirectory(at: leveldb, withIntermediateDirectories: true)
            try? "written on quit by \(self.account())".write(to: leveldb.appendingPathComponent("LOG"), atomically: true, encoding: .utf8)
            self.log("quit as \(self.account())")
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
let app = NSApplication.shared
let fake = Fake()
app.delegate = fake
app.run()
SWIFT
swiftc -O -o "$FAKE/Contents/MacOS/FakeClaude" "$T/fake.swift" 2>&1 | grep -v warning || true

# Signed in as A, the way Claude leaves its folder.
sign_in() {  # id letter
  rm -f "$D/Cookies"
  sqlite3 "$D/Cookies" "create table cookies(host_key text, name text, encrypted_value blob);
    insert into cookies values('.claude.ai','sessionKey','$2'), ('.claude.ai','lastActiveOrg','org-$2');"
  mkdir -p "$D/Local Storage/leveldb" "$D/IndexedDB/https_claude.ai_0.indexeddb.leveldb"
  echo "$2 storage" > "$D/Local Storage/leveldb/000003.log"
  echo "$2 idb" > "$D/IndexedDB/https_claude.ai_0.indexeddb.leveldb/000003.log"
  node -e '
    const fs = require("fs"), [file, id, letter] = process.argv.slice(1);
    const c = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
    Object.assign(c, { "oauth:tokenCache": "djEw" + letter, "oauth:tokenCacheV2": "djEw" + letter + "2",
      lastKnownAccountUuid: id, bootSideSessions: { accountUuid: id, supported: true } });
    fs.writeFileSync(file, JSON.stringify(c, null, "\t"));' "$D/config.json" "$1" "$2"
}
mkdir -p "$D/claude-code-sessions/$A"
printf '{\n\t"locale": "en-US",\n\t"nothing": null,\n\t"layout": {"sidebarWidth": 280.5, "collapsed": false}\n}' > "$D/config.json"
sign_in $A A
echo kept > "$D/claude-code-sessions/$A/session.json"
# Claude Code's config names the account it's signed in with.
printf '{"oauthAccount": {"accountUuid": "%s", "emailAddress": "a@example.com", "organizationName": "Example Org"}}' $A > "$T/.claude.json"

open "$FAKE"; wait_for running
check "fake Claude is running" running
check "list shows A as current, named by its email" '[[ "$(cli list)" == "* a@example.com  $A"* ]]'

echo "-- add another account"
cli add --here
check "fake Claude quit and opened again" 'wait_for running && grep -q "quit as $A" "$T/events.log" && grep -q "launched as none" "$T/events.log"'
check "Claude folder is signed out" '[[ ! -e "$D/Cookies" && ! -e "$D/Local Storage" && $(key lastKnownAccountUuid) == absent && $(key oauth:tokenCacheV2) == absent ]]'
check "other config kept, null included" '[[ $(key locale) == en-US && $(key layout.sidebarWidth) == 280.5 ]] && grep -q "\"nothing\" *: *null" "$D/config.json"'
check "sessions folder untouched" '[[ $(cat "$D/claude-code-sessions/$A/session.json") == kept ]]'
check "A saved after Claude finished quitting" 'grep -q "written on quit by $A" "$S/profiles/$A/data/Local Storage/leveldb/LOG"'
check "A saved with its cookies and tokens" '[[ $(sqlite3 "$S/profiles/$A/data/Cookies" "select encrypted_value from cookies where name=\"sessionKey\"") == A ]] && grep -q djEwA2 "$S/profiles/$A/config-keys.json"'
check "list shows A and signed out" '[[ "$(cli list)" == *"a@example.com"*"Claude is signed out"* ]]'

echo "-- sign in as B in Claude"
sign_in $B B
check "list shows B as current" 'cli list | grep -q "^\* Account bbbbbbbb"'
rm "$T/.claude.json"
check "A keeps its email name once Claude Code moves on" 'cli list | grep -q "  a@example.com  $A"'
check "B, with no email anywhere, gets a short id" 'cli list | grep -q "^\* Account bbbbbbbb"'
cli rename aaaaaaaa Work
check "rename A to Work" 'cli list | grep -q "  Work  $A"'

echo "-- switch to Work"
: > "$T/events.log"
cli switch work --here
check "Claude reopened as A" 'wait_for running && grep -q "quit as $B" "$T/events.log" && grep -q "launched as $A" "$T/events.log"'
check "A's cookie, storage and tokens are back" '[[ $(cookie) == A && $(key oauth:tokenCacheV2) == djEwA2 && $(key lastKnownAccountUuid) == $A ]] && grep -q "written on quit by $A" "$D/Local Storage/leveldb/LOG" && grep -q "A idb" "$D/IndexedDB/https_claude.ai_0.indexeddb.leveldb/000003.log"'
check "B saved with its cookie" '[[ $(sqlite3 "$S/profiles/$B/data/Cookies" "select encrypted_value from cookies where name=\"sessionKey\"") == B ]]'
check "backup holds B, the state before the switch" 'grep -q djEwB2 "$S/before-last-switch/config-keys.json"'

echo "-- switch to B by id prefix, handed off to a separate process"
: > "$T/events.log"
out=$("$BIN" --data-dir "$D" --store "$S" --claude-app "$FAKE" switch bbbb)
check "hand-off returns straight away" '[[ $out == "Switching in the background"* ]]'
check "Claude reopened as B" 'wait_for "grep -q \"launched as $B\" \"$T/events.log\""'
check "B's cookie and tokens are back" '[[ $(cookie) == B && $(key oauth:tokenCache) == djEwB ]]'
check "switching to the current account is a no-op" '[[ "$(cli switch $B --here)" == "Claude is already signed in as"* ]]'

echo "-- remove"
check "can't remove the current account" '! cli remove bbbb 2>/dev/null'
cli remove work
check "Work removed" '[[ ! -e "$S/profiles/$A" ]] && ! cli list | grep -q Work'
check "store is private" '[[ $(stat -f %Lp "$S") == 700 ]]'

echo "-- panel"
probe=$("$BIN" probe-panel)
check "panel tracks its card, so it takes clicks there and lets the rest through" '[[ $probe == *"{{24, 0}, {320, 1"[0-9][0-9]"}}"*"expanding a row"*"{{24, 0}, {320, 2"[0-9][0-9]"}}"* ]]'

pkill -f "$FAKE/Contents/MacOS/FakeClaude" || true
echo
echo "switch.log:"; sed 's/^/  /' "$S/switch.log"
echo
(( fails == 0 )) && echo "all checks passed" || { echo "$fails checks failed"; exit 1; }
