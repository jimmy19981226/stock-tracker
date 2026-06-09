#!/usr/bin/env bash
# Rebuild the sideloadable .ipa after any code change.
# Output: ios/dist/StockTracker.ipa  → add it in SideStore (My Apps → +).
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate
xcodebuild -project StockTracker.xcodeproj -scheme StockTracker -configuration Release \
  -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

APP=$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name StockTracker.app | head -1)
rm -rf dist/Payload && mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
( cd dist && rm -f StockTracker.ipa && zip -qr StockTracker.ipa Payload && rm -rf Payload )
echo "Built: $(pwd)/dist/StockTracker.ipa"
