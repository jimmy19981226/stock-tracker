# Stock Studio 2 preview

The iOS redesign uses warm neutral surfaces, a teal accent, native San Francisco typography, and a persistent five-destination tab bar. Portfolio value and market entry points lead the home screen. Each market separates searchable positions from performance analytics. Assistant suggestions populate an editable composer; writes still require the existing confirmation cards.

Design references: [Apple tab-bar guidance](https://developer.apple.com/design/human-interface-guidelines/tab-bars) for predictable destinations, and [Copilot investment overview](https://help.copilot.money/en/articles/5377645-investments-tab-overview) for consolidated investments and clear portfolio hierarchy. The visual system and implementation are original to this app.

`Theme.swift` is the source of truth for colors, typography, surfaces and spacing. Both appearances use semantic gain/loss colors, including the user's Taiwan color convention. All money continues through `Fmt`; the portfolio accounting implementation is unchanged by the visual redesign.

## Reproduce visual checks

Start the synthetic preview API from the repository root:

```sh
python3 ios/DesignPreview/server.py
```

This uses only the Python standard library. It does not load `.env`, open a database, query a market provider, or accept record mutations. Its six holdings and associated records are fictional. Do not point a real phone at this preview service.

From `ios/`:

```sh
xcodegen generate
xcodebuild test -project StockTracker.xcodeproj -scheme StockTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:StockTrackerUITests/ProductTour \
  -resultBundlePath /tmp/studio-product-tour.xcresult CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool export attachments --path /tmp/studio-product-tour.xcresult \
  --output-path /tmp/studio-product-tour
```

The tour checks market navigation, ticker search, detail navigation, editable assistant prompts, keyboard chrome, and quick trade entry. Screenshots cover home, history, holdings, detail, performance, trade entry, dividends, assistant and settings in both light and dark appearances. UI tests override the API URL only for the launched test process. Production builds retain the configured Render endpoint and account storage.

## Assistant regression checks

`AssistantReview` checks formatted tables in light/dark appearances, horizontal scrolling without losing full amounts, accessibility text, and discarding edit/delete proposals. Run it against `server.py`; the preview server rejects all record mutations. `MarkdownTextTests` covers table parsing and code preservation. `AssistantTransportTests` uses an isolated URLSession transport to exercise streamed UTF-8, agent actions, error bodies, token refresh, and interrupted replies.

For an explicitly opted-in live provider test, run `python3 ios/DesignPreview/live_ai_server.py` from the repository root, then run `StockTrackerUITests/DesignTour/testLiveCheckedPerformanceReply`. This separate server listens on port 8107 and uses the backend's synthetic account/price fixtures. It sets an isolated SQLite URL before importing backend code and never opens the production database. Only Gemini inference is live and consumes API quota. The key is read locally, never printed or copied into the iOS build.

Backend regression command (from `backend/`):

```sh
DATABASE_URL=sqlite:///:memory: RUN_GEMINI_LIVE_TESTS=0 python3 -m unittest discover -s tests -v
```

Use `RUN_GEMINI_LIVE_TESTS=1` and `-p test_gemini_live.py` only when live inference is intended. Preserve the original failures if a bounded rerun succeeds: provider timeouts or 503 responses are reliability results, not passing first attempts. No draft may change the ledger until confirmation through the normal record API.

## Keyboard and conversation navigation

Main navigation must stay visible and tappable above the keyboard. Switching tabs dismisses editing and preserves the assistant's unsent draft and ongoing reply. A modal form instead keeps its Close button reachable; closing must not submit it. Numeric trade/dividend entry includes a Done button.

Run `KeyboardNavigationTests` with both `server.py` (8099) and `interaction_server.py` (8109) running. The latter supplies a deterministic delayed SSE reply without any model call or database, allowing the UI test to leave the assistant and return while generation is in progress. The tests cover both chat themes, every destination, draft preservation, holdings search results, settings focus, numeric keyboard dismissal, trade/dividend cancellation, import cancellation, and exactly one completed response after tab switching.

`AssistantConversationTests` separately checks overlapping history loads, late recovery responses, generation/background cleanup ownership, conversation-specific attachments/proposals, and confirmed import completion after navigation. Navigation within the same conversation preserves its draft; explicitly opening another conversation clears that draft. Confirmed writes continue and refresh the shared portfolio, but their completion must not change the new conversation's transcript or proposal.

## Rotating portfolio ticker

`IndexBarView` sits directly below “Your portfolio” on Overview. It cycles configured indices every four seconds using the existing quote store; tapping advances immediately and the chevron opens details and the existing editor. Rotation pauses in the background or while details are open. It continues during iPhone Mirroring's inactive scene state. Reduce Motion disables the transition animation without disabling rotation; VoiceOver keeps manual advancement.

`MarketTickerTests` verifies placement between the title and portfolio value card, automatic advancement through at least three distinct indices, manual advance, details pause/resume, return from another tab, light/dark appearances, Reduce Motion and inactive-scene behavior. The synthetic fixture includes six indices; the live account's requested list also includes Taiwan OTC. `UITEST_REDUCE_MOTION` and `UITEST_TICKER_INACTIVE` isolate the two regression conditions without changing system settings.

## Assistant connection, feedback and recovery

Settings exposes Included AI and Personal key explicitly. Existing personal-key users keep their selection until they change it. Included AI omits the personal credential header without deleting the saved key. The model remains Gemini 3.5 Flash-Lite. Credential rejection has specific recovery guidance; unknown request errors do not get mislabeled as credential problems.

The assistant uses a compact model header, a daily-briefing entry point, quieter user bubbles, labeled replies, a visible copy action and copy confirmation. In-flight work has an actual tool-status label, elapsed time and a stop button in the composer. Message arrival, pulse and copy transitions respect Reduce Motion. Errors preserve the transcript and offer an editable question before retry. Main navigation remains accessible during composition.

The October 27 interaction benchmark reviewed OpenAI's [ChatGPT search walkthrough](https://openai.com/index/introducing-chatgpt-search/), Claude's [thinking and model controls](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings), Google's [response/model details](https://support.google.com/gemini/answer/18648722?hl=en), and Perplexity's [query walkthrough](https://www.perplexity.ai/enterprise/videos/an-introduction-to-queries). Applied patterns: a quiet reading surface, visible model identity, real progress with elapsed time, expandable reasoning, and editable follow-up actions. The app keeps its own Studio palette and native typography. Animation communicates actual state; no fabricated progress or sources are added.

Two-column metric replies fit the viewport and wrap long company names; wider comparison tables retain horizontal scrolling. Latest-answer follow-up buttons fill the composer without submitting. Fixed-size decorative/control glyphs cap their Dynamic Type scaling while answer text retains the full accessibility range. Reasoning disclosure also respects Reduce Motion.

`AssistantReview` covers welcome and reply layouts in both appearances, wide tables, maximum text size, copy feedback, Reduce Motion and proposal cancellation. `KeyboardNavigationTests` also exercises both credential choices, HTTP provider failure followed by a successful send, truncated streaming and recovery, and stop/new-chat isolation. Preview responses use synthetic data; they never spend provider quota or save portfolio records.

`Fmt.prettyDate` preserves calendar-only trade dates and converts complete UTC/offset timestamps to local dates. The date regressions use injected time zones, including DST boundaries, without changing the machine's settings.

## Current-year earnings on Overview

The portfolio hero includes a current-year section below the lifetime figures and above the quick actions. It separates realized stock P/L from dividends received, with TWD and USD displayed individually. It reads `year_realized_pl` and `year_dividends` from the existing currency summaries; it never derives realized profit from open holdings or mixes currencies. The backend replays historical purchases for cost basis and includes only sale/payment dates from January 1 through today. The fields are optional on iOS so older cached snapshots render an unavailable value until refreshed. A cached summary from another year is not relabeled as the current year.

Backend lifecycle and screenshot-import tests cover account ownership, cancellation, detached stream recovery, secret-free error boundaries, malformed provider JSON, invalid record fields and preview-only extraction. Screenshot inference runs off the event loop; a held-provider concurrency test verifies that health requests remain responsive. Live inference tests remain opt-in. On the 2026-10-27 comprehensive run, three initial provider 429 failures passed one retry each after spacing testcase starts by at least 60 seconds; preserve both initial and retry evidence when reporting reliability.

The Overview quick actions open Add trade and Add dividend sheets. `ProductTour`
checks both forms can be cancelled without saving. `MarketTickerTests` also
uses `index_preview_server.py` (port 8111) to exercise empty and failed index
history, a completed loading state, and successful Retry. The production OTC
adapter uses official TWSE MIS quotes and TPEx monthly history.
