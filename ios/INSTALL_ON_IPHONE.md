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

---

# SideStore OTA setup — what actually worked (2026-06-21)

Tailored log of the exact setup used on **this** device, so it can be repeated.

**Environment**
- Device: **iPhone 15 Pro Max (iPhone16,2), iOS 26.5 (23F77)** — too new for TrollStore.
- Free Apple ID used for signing: **jimmy19981226@gmail.com**
- Mac: Xcode 26.5, Homebrew, xcodegen 2.45.4 (all already present).
- Tooling: **iLoader 2.2.6** (the current installer — it generates the pairing
  file AND installs SideStore, replacing the old `jitterbugpair` + `AltServer`
  flow), the **LocalDevVPN** App Store app (on-device tunnel; formerly/also
  "StosVPN"), anisette server **SideStore (.io)** (a hosted/public one — do NOT
  self-host locally, that would tie every refresh to the Mac and defeat the
  computer-free goal).

**1. Build the .ipa (Mac)**
```bash
cd ios && ./rebuild-ipa.sh        # → ios/dist/StockTracker.ipa (~2.0 MB)
```

**2. Install iLoader (Mac)**
```bash
curl -fL -o /tmp/iloader.dmg \
  https://github.com/nab138/iloader/releases/latest/download/iloader-darwin-universal.dmg
hdiutil attach /tmp/iloader.dmg -nobrowse
cp -R /Volumes/iloader/iloader.app /Applications/    # case-insensitive; installs as iLoader.app
hdiutil detach /Volumes/iloader
```

**3. Install SideStore (iLoader)** — plug iPhone in via USB, unlock, **Trust**.
In iLoader: enter Apple ID + password → **Login**; select the device; pick an
installer. NOTE: on iOS 26 the standalone "SideStore (Stable)" hits a UDID bug
(see below) — the build that ended up working was plain **SideStore (Stable)**
AFTER the fix in step 5. On iPhone: **Settings → General → VPN & Device
Management → trust the Apple ID developer cert.**

**4. On iPhone:** enable **Developer Mode** (Settings → Privacy & Security →
Developer Mode → on → restart). Install **LocalDevVPN** from the App Store →
open it → **Connect** → Allow VPN config. This VPN must be ON to install/refresh.

**5. THE iOS 26 GOTCHA — "could not determine UDID / pair with iloader".**
Standalone SideStore on iOS 26.x throws this even with valid pairing + VPN
(SideStore bug #1262/#1305/#1336). What fixed it on this device — the full
re-pair + reboot sequence:
   1. iPhone on USB. In iLoader settings click **Delete Stored Pairing**.
   2. Re-select the device → it re-pairs → tap **Trust** on the iPhone.
   3. iLoader → **Manage Pairing File → Place In All Apps**.
   4. **Reboot the iPhone** (this clears the stuck on-device muxer state).
   5. Reconnect **LocalDevVPN**, open SideStore → **My Apps → Refresh All**. ✅
   (LiveContainer + SideStore is the documented fallback if the standalone one
   still fails; here the standalone build worked after the reboot, and
   LiveContainer was removed afterward with no ill effect.)

**6. Install StockTracker.ipa (PENDING — blocked by Apple's App ID limit).**
Getting the .ipa onto the phone: copy to **iCloud Drive** (`cp dist/StockTracker.ipa
~/Library/Mobile\ Documents/com~apple~CloudDocs/`) or **AirDrop** it, then in
SideStore **My Apps → "+" → Files →** pick it. SideStore signs + installs.
⚠️ **Hit the free-account cap: "cannot register more than 10 App IDs within 7
days."** Caused by the day's repeated SideStore/LiveContainer reinstalls + this
app's **two** bundle IDs (`com.aistockstudio.app` + `com.aistockstudio.app.widget`).
This is an Apple limit, no bypass. Resolution chosen: **wait** for the rolling
7-day window to free slots, then retry the install. Tips:
   - It's a **one-time** hurdle — once installed, weekly auto-refresh does NOT
     consume App IDs.
   - While waiting, do **no** extra installs/Xcode runs/re-signs (each burns more
     App IDs and pushes the reset later).
   - To halve future consumption, build **without the widget** (only 1 App ID).
     (The widget target has since been removed from the project entirely, so
     current builds already consume just 1 App ID.)
   - Never sign this Apple ID with a 2nd tool (e.g. Xcode "Run to device") — it
     revokes SideStore's cert. Keep SideStore as the only signer.

**7. Make refresh automatic (do once, keeps SideStore + the app alive).**
   - Keep **LocalDevVPN Connected** at all times (it's a local loopback — does
     NOT change your IP/location and doesn't affect Maps/internet; only one VPN
     runs at a time, so turn other VPNs like Surfshark back off afterward).
   - **Settings → General → Background App Refresh → On**, and **SideStore** on
     in that list.
   - In **SideStore → Settings → Background Refresh** = enabled; allow SideStore
     **notifications** (so a failed refresh alerts you).
   - Free-tier reality: ~7-day signature, refreshed automatically over Wi-Fi when
     VPN + background refresh are on; occasionally iOS skips the window and you
     open SideStore → **Refresh All** (~5 s). Max **3** sideloaded apps; **10**
     new App IDs per 7 days. Depends on the anisette server (SideStore .io).
