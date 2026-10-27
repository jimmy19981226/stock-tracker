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
