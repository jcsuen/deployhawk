#!/bin/bash
# DeployHawk installer — builds from source when run inside a clone,
# otherwise downloads the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/jcsuen/deployhawk/main/install.sh | bash

set -euo pipefail

REPO="jcsuen/deployhawk"
APP="/Applications/DeployHawk.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/Package.swift" ]; then
    echo "▸ Building DeployHawk from source..."
    "$SCRIPT_DIR/scripts/make-app-bundle.sh"
else
    echo "▸ Fetching latest DeployHawk release..."
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -o '"browser_download_url": *"[^"]*DeployHawk[^"]*\.zip"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
    if [ -z "$URL" ]; then
        echo "No release zip found — building from source instead."
        git clone --depth 1 "https://github.com/$REPO.git" "$TMP/deployhawk"
        "$TMP/deployhawk/scripts/make-app-bundle.sh"
    else
        curl -fsSL "$URL" -o "$TMP/DeployHawk.zip"
        rm -rf "$APP"
        ditto -xk "$TMP/DeployHawk.zip" /Applications
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    fi
fi

open "$APP"
echo "✅ DeployHawk installed. Look for the 🚀 in your menu bar."
