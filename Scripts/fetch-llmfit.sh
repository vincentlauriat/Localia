#!/usr/bin/env bash
# Installs the pinned llmfit release into Localia/Resources/llmfit (bundled into Contents/Helpers by the
# Xcode build). The SHA-256 of the tarball is pinned HERE, not read from a .sha256 file downloaded next to
# it, so a tampered release cannot vouch for itself. The verified tarball is cached in vendor/ (offline builds).
# To bump: change VERSION and SHA256 together, taking the digest from the GitHub release asset page.
set -euo pipefail

VERSION="1.1.20"
SHA256="d95629660505debdd3d8086a020512600ae1e1fcc35d89dc716424788497a73b"   # llmfit-v1.1.20-aarch64-apple-darwin.tar.gz
ASSET="llmfit-v${VERSION}-aarch64-apple-darwin.tar.gz"
REPO="AlexsJones/llmfit"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/vendor/$ASSET"
DEST="$ROOT/Localia/Resources/llmfit"

sha_ok() { [[ -f "$1" && "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$SHA256" ]]; }

# Fast path: cached archive is the pinned one and the installed binary is that version.
if sha_ok "$CACHE" && [[ -x "$DEST" ]] && "$DEST" --version 2>/dev/null | grep -q "$VERSION"; then
  echo "llmfit $VERSION already installed"
  exit 0
fi

if ! sha_ok "$CACHE"; then
  mkdir -p "$ROOT/vendor"
  TMP="$(mktemp "$ROOT/vendor/.dl.XXXXXX")"
  trap 'rm -f "$TMP"' EXIT
  curl -fsSL -o "$TMP" "https://github.com/$REPO/releases/download/v$VERSION/$ASSET"
  sha_ok "$TMP" || { echo "llmfit: SHA-256 mismatch for $ASSET (expected $SHA256)" >&2; exit 1; }
  mv "$TMP" "$CACHE"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; rm -f "${TMP:-}"' EXIT
tar -xzf "$CACHE" -C "$WORK"
BIN="$(find "$WORK" -type f -name llmfit | head -n 1)"
[[ -n "$BIN" ]] || { echo "llmfit binary not found in $ASSET" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST.tmp"
chmod +x "$DEST.tmp"
mv "$DEST.tmp" "$DEST"

"$DEST" --version
echo "OK"
