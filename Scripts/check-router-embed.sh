#!/usr/bin/env bash
# Checks that <app> embeds the Rust router as Contents/MacOS/LocaliaProxyService:
# present, a universal Mach-O (arm64 and x86_64), the Rust binary (it names LOCALIA_ROUTER_PORT), with a valid signature,
# and that the launch agent plist still points to it.
# Usage: Scripts/check-router-embed.sh path/to/Localia.app
set -euo pipefail

APP="${1:?usage: $0 path/to/Localia.app}"
BIN="$APP/Contents/MacOS/LocaliaProxyService"
PLIST="$APP/Contents/Library/LaunchAgents/fr.vincentlauriat.localia.proxy.plist"

fail() { echo "x $*" >&2; exit 1; }

[ -f "$BIN" ] || fail "missing $BIN"
ARCHS="$(lipo -archs "$BIN" 2>/dev/null | tr ' ' '\n' | sort | xargs)" || fail "not a Mach-O executable: $(file -b "$BIN")"
[ "$ARCHS" = "arm64 x86_64" ] || fail "architectures are '$ARCHS', expected arm64 and x86_64"
file -b "$BIN" | grep -c "executable" >/dev/null || fail "not a Mach-O executable: $(file -b "$BIN")"
strings -a "$BIN" | grep -c "LOCALIA_ROUTER_PORT" >/dev/null || fail "not the Rust router (no LOCALIA_ROUTER_PORT string)"
codesign --verify --strict "$BIN" || fail "invalid signature on $BIN"
[ -f "$PLIST" ] || fail "missing $PLIST"
PROGRAM="$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "$PLIST")"
[ "$PROGRAM" = "Contents/MacOS/LocaliaProxyService" ] || fail "BundleProgram is '$PROGRAM'"
echo "ok $BIN"
