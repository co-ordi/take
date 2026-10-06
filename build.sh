#!/bin/bash
# Builds Take.app from Sources/, signs it ad hoc and installs it to ~/Applications.
# Needs only the Command Line Tools (no Xcode).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Take.app"
DEST="$HOME/Applications/Take.app"

echo "Compiling..."
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 \
  -target arm64-apple-macos15.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Take"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

# Sign with the local "Take Local Signing" identity if it's in the keychain, so macOS keeps
# Take's permissions across rebuilds. Without it, fall back to ad hoc (permissions reset each build).
IDENTITY="Take Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  # Using the key can mean a macOS keychain dialog on the Mac's screen. With the screen locked
  # nobody can answer it and codesign would wait for ever, so stop with a message instead.
  if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q "<true/>"; then
    echo "The Mac's screen is locked, so macOS can't ask about the signing key. Unlock it and run this again." >&2
    exit 1
  fi
  echo "Signing with $IDENTITY..."
  echo "(If macOS asks whether codesign may use the key, enter your login password and choose Always Allow.)"
  if ! perl -e 'alarm 120; exec @ARGV' codesign --force --deep --sign "$IDENTITY" "$APP"; then
    echo "Signing didn't finish (no answer to the keychain dialog within two minutes?). Nothing was installed." >&2
    exit 1
  fi
else
  echo "Signing ad hoc (no \"$IDENTITY\" in the keychain, so macOS will ask for permissions again)..."
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP"

if pgrep -xq Take; then
  echo "Built and signed $APP, but Take is running, so it isn't installed yet." >&2
  echo "Quit it (menu bar icon > Quit Take) and run this again." >&2
  exit 1
fi

echo "Installing to $DEST..."
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --strict "$DEST"

echo "Done. Open ~/Applications/Take.app. It lives in the menu bar, not the Dock."
