#!/usr/bin/env bash
# Build -> sign (Developer ID + Hardened Runtime) -> DMG -> notarize -> staple.
#
# Usage:   ./Scripts/release.sh [version]      (default: 1.0.0)
# Output:  release/Localia-<version>.dmg       (gitignored)
#
# Shared Apple credentials (same for all Mac apps, see the macos-app-release skill):
#   - Developer ID Application: Vincent LAURIAT (KFLACS69T9)
#   - notarytool keychain profile "AppliMacVincentGithub"
# Overridable via env: SIGNING_IDENTITY, NOTARY_PROFILE, SPARKLE_ACCOUNT.
# Distributable releases (NOTARIZE != 0) need an explicit BUILD_NUMBER (monotonic, it is Sparkle's
# version), must run from the main branch, and need a non-empty SUPublicEDKey unless ALLOW_NO_UPDATES=1.
# NOTARIZE=0 builds and signs the DMG only (local check; the result is NOT distributable).
#
# Sparkle: set SPARKLE_ACCOUNT to the keychain account holding the EdDSA private key
# to also sign the DMG and write release/appcast.xml. The private key never lives in
# this repo; SUPublicEDKey in project.yml must be its public half. Never regenerate a
# key once users have installed a build carrying SUPublicEDKey.
#
# This script does NOT tag, push, publish a GitHub release or upload anything.
set -euo pipefail

VERSION="${1:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Localia"
SCHEME="Localia"
PROJECT="Localia.xcodeproj"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"
NOTARIZE="${NOTARIZE:-1}"
if [ "$NOTARIZE" = "0" ]; then
  BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [ "$BRANCH" = "main" ] || { echo "x Distributable releases run from main (on '$BRANCH'). Use NOTARIZE=0 for a local build." >&2; exit 1; }
  [ -n "${BUILD_NUMBER:-}" ] || { echo "x Set BUILD_NUMBER explicitly (monotonic, above the last published build)." >&2; exit 1; }
fi
RELEASE_DIR="$ROOT/release"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
DMG_VOLNAME="$APP_NAME $VERSION"
mkdir -p "$RELEASE_DIR"

echo "> Releasing $APP_NAME $VERSION (build $BUILD_NUMBER)"

# Fail early if the notary profile is missing (before spending time on the build).
[ "$NOTARIZE" = "0" ] || xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
  echo "x Notary profile \"$NOTARY_PROFILE\" not found. Recreate it manually:" >&2
  echo "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <your-apple-id> --team-id KFLACS69T9" >&2
  exit 1
}

# 1. Regenerate the Xcode project. The pre-build phase runs Scripts/fetch-llmfit.sh,
#    which fails the build when the pinned llmfit checksum does not match.
echo "> xcodegen generate"
xcodegen generate >/dev/null

# 2. Release build. Signing is done by hand below (CODE_SIGNING_ALLOWED=NO avoids the
#    com.apple.provenance xattr problem).
echo "> xcodebuild Release"
rm -rf "$ROOT/build"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  build >"$RELEASE_DIR/xcodebuild.log" 2>&1 || { tail -30 "$RELEASE_DIR/xcodebuild.log" >&2; exit 1; }
APP="$ROOT/build/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "x App not found: $APP" >&2; exit 1; }

# 3. Stage a clean copy without extended attributes.
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGING="$STAGING_DIR/$APP_NAME.app"
ditto --norsrc --noextattr --noacl "$APP" "$STAGING"

# Sparkle command-line tools, pinned and checksum-verified (same version as the framework in project.yml).
SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE_TOOLS="$ROOT/.sparkle-tools/$SPARKLE_VERSION"
fetch_sparkle_tools() {
  [ -x "$SPARKLE_TOOLS/bin/sign_update" ] && return 0
  local tarball="$STAGING_DIR/Sparkle.tar.xz"
  curl -fsSL -o "$tarball" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$SPARKLE_SHA256" ] || { echo "x Sparkle tarball checksum mismatch" >&2; exit 1; }
  mkdir -p "$SPARKLE_TOOLS" && tar -xJf "$tarball" -C "$SPARKLE_TOOLS"
}

# Update-key guards for distributable releases.
STAGED_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$STAGING/Contents/Info.plist" 2>/dev/null || true)"
if [ "$NOTARIZE" != "0" ] && [ -z "$STAGED_KEY" ] && [ "${ALLOW_NO_UPDATES:-0}" != "1" ]; then
  echo "x SUPublicEDKey is empty: this build could never update. Set it in project.yml, or ALLOW_NO_UPDATES=1." >&2
  exit 1
fi
if [ -n "${SPARKLE_ACCOUNT:-}" ]; then
  fetch_sparkle_tools
  ACCOUNT_KEY="$("$SPARKLE_TOOLS/bin/generate_keys" -p --account "$SPARKLE_ACCOUNT")"
  [ "$ACCOUNT_KEY" = "$STAGED_KEY" ] || { echo "x Keychain account '$SPARKLE_ACCOUNT' key differs from SUPublicEDKey in the app." >&2; exit 1; }
fi

# 4. Sign deepest first. Apple's timestamp server is flaky: retry.
codesign_ts() {
  local target="$1" i
  for i in 1 2 3 4 5; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$target"; then
      return 0
    fi
    echo "  ...codesign retry $i/5 in 5s" >&2
    sleep 5
  done
  echo "x codesign failed for $target" >&2
  return 1
}

echo "> codesign Contents/Helpers/llmfit (before the app)"
codesign_ts "$STAGING/Contents/Helpers/llmfit"

SPARKLE_FW="$STAGING/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  echo "> codesign Sparkle.framework (nested code first)"
  SV="$SPARKLE_FW/Versions/B"
  for item in "$SV/Autoupdate" "$SV/XPCServices/Downloader.xpc" "$SV/XPCServices/Installer.xpc" "$SV/Updater.app"; do
    [ -e "$item" ] && codesign_ts "$item"
  done
  codesign_ts "$SPARKLE_FW"
fi

echo "> codesign $APP_NAME.app"
codesign_ts "$STAGING"
codesign --verify --deep --strict --verbose=2 "$STAGING"

# 5. DMG with a Finder layout via dmgbuild (pinned, hash-checked venv). No Finder AppleScript.
DMG_BG="$STAGING_DIR/background.png"
"$ROOT/Scripts/make-dmg-background.swift" "$DMG_BG" >/dev/null
DMGBUILD_REQS="$ROOT/Scripts/dmgbuild-requirements.txt"
DMGBUILD_VENV="$ROOT/.dmgbuild-venv/$(shasum -a 256 "$DMGBUILD_REQS" | cut -c1-12)"
if [ ! -x "$DMGBUILD_VENV/bin/dmgbuild" ]; then
  echo "> installing dmgbuild (one-time)"
  rm -rf "$DMGBUILD_VENV"
  python3 -m venv "$DMGBUILD_VENV"
  "$DMGBUILD_VENV/bin/pip" install --quiet --disable-pip-version-check \
    --only-binary=:all: --require-hashes -r "$DMGBUILD_REQS"
fi
rm -f "$DMG"
echo "> dmgbuild $DMG"
"$DMGBUILD_VENV/bin/dmgbuild" -s "$ROOT/Scripts/dmg-settings.py" \
  -D app="$STAGING" -D background="$DMG_BG" \
  "$DMG_VOLNAME" "$DMG" 2> >(grep -v "is deprecated" >&2) >/dev/null
codesign_ts "$DMG"

if [ "$NOTARIZE" = "0" ]; then
  MOUNT="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$DMG" | awk -F '\t' 'END {print $NF}')"
  codesign --verify --deep --strict --verbose=2 "$MOUNT/$APP_NAME.app"
  hdiutil detach "$MOUNT" -quiet
  echo "Done (NOT notarized, NOT distributable): $(ls -la "$DMG")"
  exit 0
fi

# 6. Notarize: only "Accepted" on THIS dmg counts.
echo "> notarytool submit --wait"
NOTARY_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$NOTARY_OUT"
if ! echo "$NOTARY_OUT" | grep -q "status: Accepted"; then
  echo "x Notarization was not Accepted. Read the log with: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 7. Independent verification on the mounted, stapled DMG.
MOUNT="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$DMG" | awk -F '\t' 'END {print $NF}')"
trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$STAGING_DIR"' EXIT
codesign --verify --deep --strict "$MOUNT/$APP_NAME.app"
spctl -a -t exec -vv "$MOUNT/$APP_NAME.app"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true

# 8. Optional Sparkle signature + appcast item (written under release/, not into the repo).
if [ -n "${SPARKLE_ACCOUNT:-}" ]; then
  fetch_sparkle_tools
  TOOLS="$SPARKLE_TOOLS"
  SIG_LINE="$("$TOOLS/bin/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"
  BUILT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$STAGING/Contents/Info.plist")"
  cat > "$RELEASE_DIR/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Localia</title>
    <link>https://raw.githubusercontent.com/vincentlauriat/Localia/main/appcast.xml</link>
    <description>Localia release feed</description>
    <language>en</language>
    <item>
      <title>v$VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILT_BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/vincentlauriat/Localia/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/vincentlauriat/Localia/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg" type="application/octet-stream" $SIG_LINE />
    </item>
  </channel>
</rss>
APPCAST
  echo "> wrote $RELEASE_DIR/appcast.xml (review it, then merge into the repo's appcast.xml)"
else
  echo "> SPARKLE_ACCOUNT not set: DMG not Sparkle-signed, no appcast item generated"
fi

echo
echo "Done: $(ls -la "$DMG")"
echo "Not published. Publishing (tag, GitHub release, appcast push) needs Vincent's go-ahead."
