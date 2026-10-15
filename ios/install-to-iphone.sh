#!/usr/bin/env bash
# Build, sign with the free Apple Developer team, and install onto the USB-connected iPhone.
# Free-account signatures expire after 7 days: re-run this script to renew (the app and its data stay).
# Requires: Xcode, xcodegen, the iPhone plugged in + unlocked + Developer Mode on.
# NOTE: do not mix with SideStore on the same Apple ID — Xcode signing revokes SideStore's certificate.
set -euo pipefail
cd "$(dirname "$0")"

UDID="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $3; exit}')}"
[ -n "$UDID" ] || { echo "No connected iPhone found. Plug it in and unlock it."; exit 1; }
echo "Target device: $UDID"

xcodegen generate >/dev/null

# Build with automatic signing so Xcode fetches/renews the team profile, but sign manually afterwards:
# the project lives in an iCloud-synced folder, whose Finder/provenance xattrs make Xcode's own
# CodeSign step fail with "resource fork, Finder information, or similar detritus not allowed".
xcodebuild -project StockTracker.xcodeproj -scheme StockTracker -configuration Release \
  -destination "id=$UDID" -derivedDataPath build-device -allowProvisioningUpdates build \
  CODE_SIGNING_ALLOWED=NO > build-device/build.log 2>&1 || { tail -30 build-device/build.log; exit 1; }

SRC=$(find build-device/Build/Products/Release-iphoneos -maxdepth 1 -name StockTracker.app | head -1)
XCENT=$(find build-device/Build/Intermediates.noindex -name "StockTracker.app.xcent" | head -1)
PROFILE=$(ls -t ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision | while read -r p; do
  security cms -D -i "$p" 2>/dev/null | grep -q "D77DF52MVG.com.aistockstudio.app</string>" && echo "$p" && break; done)
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
[ -n "$PROFILE" ] && [ -n "$IDENTITY" ] || { echo "Missing provisioning profile or signing identity. Open the project in Xcode once, signed in with the team's Apple ID."; exit 1; }

# Copy without extended attributes (ditto), embed the profile, write entitlements if the build didn't, sign.
OUT=$(mktemp -d /tmp/stocktracker-signed.XXXX)
ditto --noextattr --norsrc --noqtn "$SRC" "$OUT/StockTracker.app"
cp "$PROFILE" "$OUT/StockTracker.app/embedded.mobileprovision"
if [ -z "$XCENT" ]; then
  XCENT="$OUT/ent.plist"
  cat > "$XCENT" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>D77DF52MVG.com.aistockstudio.app</string>
  <key>com.apple.developer.team-identifier</key><string>D77DF52MVG</string>
  <key>get-task-allow</key><true/>
</dict></plist>
ENT
fi
codesign --force --sign "$IDENTITY" --entitlements "$XCENT" --timestamp=none --generate-entitlement-der "$OUT/StockTracker.app"
codesign --verify --strict "$OUT/StockTracker.app"

xcrun devicectl device install app --device "$UDID" "$OUT/StockTracker.app" | grep -E "bundleID|installationURL" || true
xcrun devicectl device process launch --device "$UDID" com.aistockstudio.app >/dev/null 2>&1 \
  || echo "Installed. If it did not open: iPhone Settings → General → VPN & Device Management → trust the developer app (one-time)."
echo "Done. Signature valid until: $(security cms -D -i "$PROFILE" | plutil -extract ExpirationDate raw -)"
