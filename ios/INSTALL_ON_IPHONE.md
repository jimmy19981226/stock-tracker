# Installing on your iPhone — permanently, no App Store

This app is for **your personal iPhone only**. Apple's own signing makes
non-App-Store apps expire (free Apple ID = 7 days, paid = 1 year). To run it
**forever without the App Store**, use a community sideloader. All of them
install the same file: **`dist/StockTracker.ipa`** (already built).

First check your iOS version: **Settings → General → About → Software Version.**

---

## Option A — TrollStore (truly permanent, free, no computer)

If your iPhone runs **iOS ~14.0–16.6.1** (or **17.0** on some models), TrollStore
installs apps that **never expire** and never need re-signing.

1. Install TrollStore using the official guide for your iOS version:
   <https://ios.cfw.guide/installing-trollstore/>
2. Open **TrollStore → "+"** and pick `StockTracker.ipa`
   (AirDrop / iCloud Drive the file to your phone first, or host it and open the URL).
3. Tap **Install**. Done — permanent, no expiry, no refresh.

> Check eligibility at <https://ios.cfw.guide> — TrollStore only works on the iOS
> versions where the underlying bug is unpatched. If you're on a newer iOS, use
> Option B.

---

## Option B — SideStore (any iOS; auto-refreshes so it never expires in practice)

SideStore signs the app with your **free Apple ID** and **re-signs it
automatically on-device over Wi-Fi**, so it keeps working indefinitely — no
computer needed after the one-time setup.

1. Follow the SideStore setup once: <https://sidestore.io> (pairs your phone,
   installs SideStore itself). You'll need a free Apple ID.
2. In SideStore, tap **"+"** and choose `StockTracker.ipa`.
3. Enable **background refresh** for SideStore so it renews the signature before
   the 7-day window lapses. After that it just keeps running.

> AltStore (<https://altstore.io>) is the same idea but needs **AltServer** running
> on a Mac/PC on the same network to refresh — fine if a computer is usually around.

---

## Option C — Paid Apple Developer ($99/yr)

If you'd rather pay: join the Apple Developer Program, open the project in Xcode
(`xcodegen generate && open StockTracker.xcodeproj`), set your Team in Signing &
Capabilities, and **Run** to your iPhone. Re-install once a year. Simplest, but
costs money and still technically expires yearly.

---

## Rebuilding the .ipa after code changes

```bash
cd ios
xcodegen generate   # if project.yml changed
xcodebuild -project StockTracker.xcodeproj -scheme StockTracker -configuration Release \
  -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
APP=$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name StockTracker.app | head -1)
mkdir -p dist/Payload && cp -R "$APP" dist/Payload/
( cd dist && zip -qr StockTracker.ipa Payload && rm -rf Payload )
# → dist/StockTracker.ipa
```

## Notes
- The app talks to your **Render backend** (always-on), so once installed it works
  anywhere on Wi-Fi or cellular — nothing else needs to run on your phone or Mac.
- Bundle id is `com.aistockstudio.app`. The display name is "Stock Studio".
- This `.ipa` is **unsigned** on purpose — TrollStore/SideStore/AltStore apply
  their own signature during install.
