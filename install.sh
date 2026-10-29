#!/bin/zsh
# Builds, copies the app to ~/Applications and opens it in the menu bar.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
pkill -x ClaudeAccounts 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/"Claude Accounts.app"
cp -R "build/Claude Accounts.app" ~/Applications/
open ~/Applications/"Claude Accounts.app"
echo "Installed ~/Applications/Claude Accounts.app"
