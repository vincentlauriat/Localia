#!/usr/bin/env bash
# Fetches the pinned llmfit release, verifies its SHA-256 and installs the binary
# into Localia/Resources/llmfit (bundled into Contents/Helpers by the Xcode build).
set -euo pipefail

VERSION="1.1.20"
ASSET="llmfit-v${VERSION}-aarch64-apple-darwin.tar.gz"
REPO="AlexsJones/llmfit"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor"
DEST="$ROOT/Localia/Resources/llmfit"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Prefer the verified tarball cached in vendor/, else download it.
if [[ -f "$VENDOR/$ASSET" && -f "$VENDOR/$ASSET.sha256" ]]; then
  cp "$VENDOR/$ASSET" "$VENDOR/$ASSET.sha256" "$WORK/"
elif command -v gh >/dev/null 2>&1 && gh release download "v$VERSION" -R "$REPO" -D "$WORK" -p "$ASSET*" 2>/dev/null; then
  :
else
  URL="https://github.com/$REPO/releases/download/v$VERSION"
  curl -fsSL -o "$WORK/$ASSET" "$URL/$ASSET"
  curl -fsSL -o "$WORK/$ASSET.sha256" "$URL/$ASSET.sha256"
fi

(cd "$WORK" && shasum -a 256 -c "$ASSET.sha256")

EXTRACT="$WORK/extract"
mkdir "$EXTRACT"
tar -xzf "$WORK/$ASSET" -C "$EXTRACT"
BIN="$(find "$EXTRACT" -type f -name llmfit | head -n 1)"
[[ -n "$BIN" ]] || { echo "llmfit binary not found in $ASSET" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST.tmp"
chmod +x "$DEST.tmp"
mv "$DEST.tmp" "$DEST"

"$DEST" --version
echo "OK"
