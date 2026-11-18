#!/usr/bin/env bash
# Builds the Rust router (the LocaliaProxyService binary): universal (arm64 + x86_64, so Intel Macs keep the
# router as they kept the 1.3 Swift proxy), minimum macOS 14.0 for both slices, release profile.
# The result is LocaliaRouter/dist/LocaliaProxyService; signing and notarization are done by release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)

if [[ ! -x "$CARGO" ]]; then
  echo "x cargo not found at $CARGO" >&2
  exit 1
fi

SLICES=()
for target in "${TARGETS[@]}"; do
  MACOSX_DEPLOYMENT_TARGET=14.0 "$CARGO" build --release --locked --target "$target" \
    --manifest-path "$ROOT/LocaliaRouter/Cargo.toml"
  SLICES+=("$ROOT/LocaliaRouter/target/$target/release/LocaliaProxyService")
done

mkdir -p "$ROOT/LocaliaRouter/dist"
lipo -create "${SLICES[@]}" -output "$ROOT/LocaliaRouter/dist/LocaliaProxyService"
echo "ok $ROOT/LocaliaRouter/dist/LocaliaProxyService ($(lipo -archs "$ROOT/LocaliaRouter/dist/LocaliaProxyService"))"
