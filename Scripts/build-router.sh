#!/usr/bin/env bash
# Builds the Rust router (the LocaliaProxyService binary): arm64, minimum macOS 14.0, release profile.
# The result is LocaliaRouter/dist/LocaliaProxyService; signing and notarization are done by release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
TARGET=aarch64-apple-darwin

if [[ ! -x "$CARGO" ]]; then
  echo "x cargo not found at $CARGO" >&2
  exit 1
fi

MACOSX_DEPLOYMENT_TARGET=14.0 "$CARGO" build --release --locked --target "$TARGET" \
  --manifest-path "$ROOT/LocaliaRouter/Cargo.toml"

mkdir -p "$ROOT/LocaliaRouter/dist"
cp "$ROOT/LocaliaRouter/target/$TARGET/release/LocaliaProxyService" "$ROOT/LocaliaRouter/dist/LocaliaProxyService"
echo "ok $ROOT/LocaliaRouter/dist/LocaliaProxyService"
