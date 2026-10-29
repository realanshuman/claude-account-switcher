#!/bin/zsh
# Builds Claude Accounts with SwiftPM and assembles build/Claude Accounts.app.
set -euo pipefail
cd "$(dirname "$0")"

# The standalone Command Line Tools build fine even when the Xcode license is not accepted.
if [[ -z "${DEVELOPER_DIR:-}" && -x /Library/Developer/CommandLineTools/usr/bin/swift ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

CONFIG=${1:-release}
swift build -c "$CONFIG"

APP="build/Claude Accounts.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/ClaudeAccounts" "$APP/Contents/MacOS/ClaudeAccounts"
cp Resources/Info.plist "$APP/Contents/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Ad-hoc, with a stable designated requirement so Open at Login survives rebuilds.
codesign --force --sign - --identifier "com.anshumanbiz.ClaudeAccounts" \
  -r "=designated => identifier \"com.anshumanbiz.ClaudeAccounts\"" "$APP" >/dev/null
echo "Built $APP"
