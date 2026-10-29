# Claude Accounts

A menu bar app that switches the Claude Mac app between accounts without signing out.

Website: https://claude-account-switcher-phi.vercel.app

Claude keeps one signed-in account at a time. Signing out ends that session on
Anthropic's side, so switching means signing in again every time. Claude Accounts files
away the current account's sign-in, puts the other account's in place and reopens Claude.
Neither account is ever signed out, so switching back is one click.

## Use

```bash
./install.sh
```

That builds the app, copies it to `~/Applications/Claude Accounts.app` and opens it in
the menu bar (the two-people icon). Click the icon for the accounts panel. If the icon is
hidden behind the notch, open the app again from Finder, Spotlight or Raycast and the
panel opens at the top of the screen.

- **Click an account** and confirm to switch. The panel ticks through each step (quit
  Claude, save the account you're leaving, sign in, open Claude) and closes when Claude
  is back. If Claude asks whether to quit, the panel says so, and Cancel stops the switch
  with nothing changed.
- **Add another account**: Claude quits and opens at the sign-in screen. Sign in with the
  other account. The account you were on is saved and stays in the list.
- **Rename** and **Remove** are in each account's ⋯ menu, or on right-click. Rename
  edits the name in place: Return saves, Esc cancels. Accounts are named by their email
  when Claude Code knows it.
- The ⋯ menu at the top has **Open at Login**, the saved sign-ins folder, and Quit.
- Esc steps back out of a confirmation, then closes the panel. Clicking anywhere else
  closes it too.

To switch, don't use Log out in Claude. It ends the session, and the saved sign-in for
that account stops working until you add it again.

Switching restarts Claude, so anything running in it stops. Code tab sessions stay in the
sidebar, filed under their own account.

## How it works

Claude's data lives in `~/Library/Application Support/Claude`. Almost everything there is
already filed by account id (Code sessions, agent sessions, scratch workspaces), so each
account sees its own. Only this belongs to whoever is signed in, and it is what gets swapped:

- `Cookies` and `Cookies-journal`: the claude.ai session cookie
- `Local Storage`, `Session Storage`, `IndexedDB`, `WebStorage`, `Service Worker`: claude.ai's web storage
- in `config.json`: `oauth:tokenCache`, `oauth:tokenCacheV2`, `lastKnownAccountUuid`, `bootSideSessions`

The cookies and token caches are encrypted with the Mac's "Claude Safe Storage" keychain
key, which is the same whichever account is signed in, so a saved sign-in works as is.
Nothing is decrypted, sent anywhere or read from the keychain.

A switch:

1. asks Claude to quit the normal way and waits for it, its helpers and any pending update
   install to finish (if Claude reopens on its own, it stops without changing anything)
2. copies the current sign-in to `before-last-switch`
3. saves the signed-in account to `profiles/<account id>`
4. puts the chosen account's sign-in in place, or none for Add Another Account
5. opens Claude

If a step fails it puts the previous sign-in back. Saved sign-ins live in
`~/Library/Application Support/Claude Accounts` (only your user can read it), and each
step is logged to `switch.log` there.

A saved sign-in lasts as long as Claude's own session for it. If one has expired, Claude
opens at the sign-in screen. Sign in with that account and it's saved again on the next
switch. A future Claude update could move sign-in somewhere else. Then a switch would
open Claude at the sign-in screen, and the fix is to update the list in
`Sources/ClaudeAccounts/AccountStore.swift`.

## Command line

```bash
"$HOME/Applications/Claude Accounts.app/Contents/MacOS/ClaudeAccounts" list
```

`list`, `status`, `switch <name, id or id prefix>`, `add`, `rename <account> <name>`,
`remove <account>`. `switch` and `add` hand the work to a separate process, so they
work even from a terminal inside Claude, which quits mid-switch.

## Build and test

```bash
./build.sh
```

```bash
scripts/test.sh
```

The test runs every switch against a fake Claude app and a fake data folder. It never
quits or touches the real Claude. It needs `node` and `sqlite3`.

## License

MIT. See [LICENSE](LICENSE).

The landing page is `docs/index.html`, deployed to Vercel (`vercel.json` serves only `docs/`). Pushes to main deploy it, and so does `npx vercel deploy --prod`. Preview it locally:

```bash
node scripts/serve-site.mjs
```
