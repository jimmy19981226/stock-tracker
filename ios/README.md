# AI Stock Studio — iOS app

A native **SwiftUI** iPhone app for the stock tracker. It talks to the existing
FastAPI backend (`../backend`) over HTTP — there is no web view, this is a real
native app. Unlike the browser frontend, native `URLSession` is not subject to
CORS, so it calls the API directly.

## Requirements

- Xcode 16+ (developed against Xcode 26.5)
- [XcodeGen](https://github.com/yonggit/XcodeGen) (`brew install xcodegen`) — the
  `.xcodeproj` is generated from `project.yml`, so it isn't committed.

## Generate the project

```bash
cd ios
xcodegen generate
open StockTracker.xcodeproj
```

## Run

The app **defaults to the deployed Render backend**
(`https://ai-stock-studio.onrender.com`), which reads the production Neon
database — so it works out of the box on the simulator or a real device with
**no local server needed**. Just run it from Xcode.

> Render's free tier sleeps after ~15 min idle, so the first request after a
> while takes ~30–60s to wake up, then it's fast.

To use a **local dev backend** instead (e.g. to test code changes):

1. Start it from the repo root:
   ```bash
   cd backend
   python3 -m uvicorn app.main:app --reload --port 8011
   ```
2. In the app, open **Settings** (gear icon, top-right of the Portfolio tab) and
   set the backend URL to `http://127.0.0.1:8011` (simulator) — or your Mac's
   LAN IP on a physical device, with the server started using `--host 0.0.0.0`.

See `docs/SELF_HOSTING_WINDOWS.md` for running your own always-on backend.

Or build + launch from the command line:

```bash
xcodebuild -project StockTracker.xcodeproj -scheme StockTracker \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install "iPhone 17" "$(find ~/Library/Developer/Xcode/DerivedData/StockTracker-*/Build/Products/Debug-iphonesimulator -name StockTracker.app | head -1)"
xcrun simctl launch "iPhone 17" com.aistockstudio.app
```

## Structure

```
StockTracker/
  App/            App entry point
  Config/         Backend base-URL (persisted in UserDefaults)
  Networking/     APIClient — async/await wrapper + SSE streaming for the AI chat
  Models/         Codable models mirroring the FastAPI schemas
  Stores/         PortfolioStore — loads data, per-market slices, live polling
  Theme/          Colors, spacing, the reusable Card container
  Util/           Formatters + market-session helper
  Views/
    Overview/     Net-worth hero + per-market cards (landing)
    Portfolio/    Segmented Dashboard / Trades / Dividends
    Trades/       Trade log + add/edit form
    Dividends/    Dividend log + add/edit form
    StockDetail/  Live quote, price chart with trade markers, position, fundamentals
    Assistant/    Streaming AI chat (SSE)
    Settings/     Backend URL editor
```

## Native iOS design choices

- **Bottom tab bar** (Portfolio / Assistant) replaces the web app's top nav.
- **Navigation hierarchy**: Overview → market portfolio → stock detail, via
  `NavigationStack`.
- **Segmented control** for Dashboard / Trades / Dividends inside a portfolio.
- **Swift Charts** for the earnings and price-history charts.
- Sheets for add/edit forms, dark "studio" theme, rounded cards, SF Rounded
  numerals, and the green/red P&L semantics carried over from the web app.
- Live polling while a portfolio is on screen (5s while that market is open,
  60s otherwise) — the same cadence as the web app.

### Testing hook

Launching with the `UITEST_MARKET=TW|US` environment variable deep-links
straight into that portfolio (used for automated screenshots):

```bash
SIMCTL_CHILD_UITEST_MARKET=TW xcrun simctl launch "iPhone 17" com.aistockstudio.app
```
