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
