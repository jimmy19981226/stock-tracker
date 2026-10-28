# AI Stock Studio — iOS app

A native **SwiftUI** iPhone app for the stock tracker. It talks to the existing
FastAPI backend (`../backend`) over HTTP — there is no web view, this is a real
native app. Unlike the browser frontend, native `URLSession` is not subject to
CORS, so it calls the API directly.

## Current release: 2.0.14 (build 21)

Studio 2 uses native iOS typography, teal and neutral surfaces, light/dark
appearances, and five persistent tabs: Overview, Trades, Assistant, Dividends,
and Settings. The tab bar remains reachable during keyboard input.

The inset navigation dock highlights the full selected item, keeps all five
destinations visible above the keyboard, and uses a short selection fade that respects Reduce Motion.

Overview welcomes the signed-in user by first name using the iPhone’s local
time. The greeting refreshes while the page is open; “Your portfolio” remains
as a smaller subtitle. Guests and profiles without a usable name get a neutral
greeting.

Overview rotates configured indices below the title. One portfolio card combines
value, today’s move, lifetime figures, and current-year realized stock P/L and
dividends received in TWD and USD. Add trade and Add dividend sit below the combined card. Taiwan uses
moving-average cost; US positions use FIFO.
YTD totals include sales and dividend payments from January 1 through today,
including closed positions and cost basis from earlier purchases.

The assistant offers editable welcome prompts and follow-ups, Markdown tables,
copy feedback, actual tool status with elapsed time, stop/recovery controls, and
Reduce Motion support. Main navigation preserves drafts and ongoing replies.

See the [current screenshots](../docs/GALLERY.md) and
[design preview/test guide](DesignPreview/README.md). Demonstration screenshots
use synthetic data.

## Requirements

- Xcode 16+ (developed against Xcode 26.5)
- [XcodeGen](https://github.com/yonggit/XcodeGen) (`brew install xcodegen`) — the
  `.xcodeproj` is generated from `project.yml`; regenerate it after spec changes.

## Generate the project

```bash
cd ios
xcodegen generate
open StockTracker.xcodeproj
```

## Run

The app configuration includes a hosted Render backend URL. For development,
set your own URL before entering records; the hosted default is not a test
fixture. Free hosting can sleep, and authentication, database access, market
feeds, or AI providers can add latency. A successful local test does not imply
that hosted requests will always be fast.

To use a **local dev backend** instead (e.g. to test code changes):

1. Start it from the repo root:
   ```bash
   cd backend
   DATABASE_URL=sqlite:////tmp/stock-studio-dev.db python3 -m uvicorn app.main:app --reload --port 8011
   ```
2. In the app, open **Settings → Connection settings** and
   set the backend URL to `http://127.0.0.1:8011` (simulator) — or your Mac's
   LAN IP on a physical device, with the server started using `--host 0.0.0.0`.

See [`docs/SELF_HOSTING_WINDOWS.md`](../docs/SELF_HOSTING_WINDOWS.md) for running your own always-on backend.

Or build + launch from the command line:

```bash
xcodebuild -project StockTracker.xcodeproj -scheme StockTracker \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install "iPhone 17" "$(find ~/Library/Developer/Xcode/DerivedData/StockTracker-*/Build/Products/Debug-iphonesimulator -name StockTracker.app | head -1)"
xcrun simctl launch "iPhone 17" com.aistockstudio.app
```

## AI assistant

The iOS assistant uses **Gemini 3.5 Flash-Lite** (`gemini-3.5-flash-lite`).
In **Settings → AI assistant**, choose:

- **Included AI:** use the Gemini key configured on your backend. This requires
  server-side configuration; the app does not bundle a provider credential.
- **Personal key:** use a Gemini key from [Google AI Studio](https://aistudio.google.com/apikey),
  stored in iOS Keychain and sent to your backend per request.

Switching to Included AI preserves the personal key but omits it from requests.
Rejected credentials have specific recovery guidance. Old model/provider
preferences cannot override the selected iOS model. There is no Groq/GPT-OSS
model selector in this release.

Chat streams replies, accepts images, and keeps the existing portfolio tools and
confirmation cards. The backend uses minimal thinking for this model. Install the
updated `backend/requirements.txt` dependencies and redeploy the backend together
with the app update; Gemini tool calls must retain their thought signatures and
function-call IDs between requests.

The assistant can read both markets' holdings, the full trade/dividend history
(including notes and fees), FIFO lots, performance, followed indices, and market
data through account-scoped tools. Record edits invalidate the assistant's cached
snapshot immediately. History tools return consecutive pages with counts rather
than sampling away rows. Attached images are sent to Gemini and retained in chat
history for follow-up questions.

The agent also supports inclusive date filters, complete record totals grouped
by ticker/month/market, calendar or rolling performance comparisons, and per-stock
profit attribution that reconciles with portfolio returns. Quantitative Gemini
answers use source references: the server copies values into tables or JSON,
keeping full numbers, currencies and valuation dates. Missing data stays unavailable.
Chat starts with a small account index, runs independent reads concurrently, and
can return already-checked data when available after a provider failure or tool-round limit; otherwise it reports an error. External availability and response time are not guaranteed.

From the repository root, run the isolated backend feature tests:

```bash
DATABASE_URL=sqlite:///:memory: PYTHONPATH=backend \
  python3 -m unittest discover -s backend/tests -v
```

These tests replace Gemini's network transport. To verify real model replies,
image reading, tool calls, and latency, configure `GOOGLE_AI_API_KEY` in
`backend/.env` or the environment, then explicitly opt into the live checks:

```bash
RUN_GEMINI_LIVE_TESTS=1 DATABASE_URL=sqlite:///:memory: PYTHONPATH=backend \
  python3 -m unittest discover -s backend/tests -p 'test_gemini_live.py' -v
```

Live checks use synthetic portfolio records in an isolated database. They do not
change your real portfolio or read the production database.

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
    Overview/     Net worth, rotating indices, YTD earnings, market cards
    Portfolio/    Market dashboard with Holdings / Performance sections
    Trades/       Trade log + add/edit form
    Dividends/    Dividend log + add/edit form
    StockDetail/  Live quote, price chart with trade markers, position, fundamentals
    Assistant/    Streaming AI chat (SSE)
    Settings/     Connection, appearance, AI credentials, reports, indices
```

## Native iOS design choices

- Five persistent bottom destinations, with Overview → market → stock detail.
- Separate Holdings / Performance sections within each market.
- Native Swift Charts, searchable holdings, and full-height record forms with
  reachable Close/Done controls.
- Light, dark, and system appearances; configurable Taiwan/US gain-color
  conventions; directional glyphs accompany P/L color.
- Dynamic Type and Reduce Motion support. Fixed-size navigation glyphs cap
  scaling while reading content retains accessibility text sizes.
- Quote publication every five seconds while a market is open and a slower
  refresh while markets are closed, with available last-close data preserved.

## Verification

The 2.0.14 update passed 56 iOS unit tests and 128 offline backend tests (12 live
provider cases skipped), plus 18 distinct targeted UI checks. YTD checks exercise both appearances,
large text, separate currencies, and navigation. Full product tours generate the
README screenshots. See [the preview guide](DesignPreview/README.md) for commands.
Never run a test fixture against the hosted portfolio or a production database.

### Testing hook

Launching with the `UITEST_MARKET=TW|US` environment variable deep-links
straight into that portfolio (used for automated screenshots):

```bash
SIMCTL_CHILD_UITEST_MARKET=TW xcrun simctl launch "iPhone 17" com.aistockstudio.app
```
