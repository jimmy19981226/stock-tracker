# AI Stock Studio — iOS changelog

The version shown on the splash screen comes from `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` in [`project.yml`](project.yml), read back at runtime
via `AppConfig.versionDisplay`. There is no second place to edit.

**Releasing:** bump both values in `project.yml`, add an entry at the top of
this file, run `xcodegen generate`, then build. Marketing version is
`MAJOR.MINOR.PATCH`; the build number increments on every build you install
anywhere, even for the same marketing version.

---

## 1.2.0 (build 3) — 2026-08-17

Rebuilt the whole iOS UI to the `design_handoff_ios_ui/` spec.

### Design language
- **New palette and type.** Light technical ground, steel-blue accent, grouped
  white cards with a soft shadow (no borders), and exactly one dark hero field
  per screen. Barlow Condensed SemiBold carries every number and heading;
  Barlow carries prose. Both faces are bundled (OFL) and registered via
  `UIAppFonts` — the design does not survive the system face.
- **Light / Dark / System.** Both themes are fully defined and resolved from
  the trait collection, so no view branches on `colorScheme`. The app no longer
  pins `UIUserInterfaceStyle: Dark`, and the launch screen follows.
- **Gain/loss is a user setting.** `Theme.pl(_:)` returns green-up (US) or
  red-up (TW); nothing names a hue at a call site. Every P&L value pairs the
  colour with a ▲/▼ glyph.
- **One ladder per dimension** — `Theme.Typo`, `Theme.Space`, `Theme.Radius`,
  and the colour tokens. One segmented control serves periods, filters and
  sorting.

### Structure
- **Five tabs**, drawn rather than `TabView`'s: Overview, Trades, Assistant,
  Dividends, Settings. Trades and Dividends are now whole-portfolio screens
  with market/status filters instead of sub-tabs of one market.
- **Overview** leads with the combined net worth in NT$, a four-column stat
  strip quoted in US$ (today / unrealized / realized + dividends / total
  return), the net-worth curve (1M–MAX) and a tappable card per market.
- **Market dashboard** leads with total earned (realized + dividends), a 2×3
  stat grid, the total-earned curve, Performance (TWR / annualized / vs a
  tappable benchmark, plus 12 months of P&L), and a holdings list with weight
  bars and a Value/Today/Gain sort.
- **Stock detail** gains trade markers on the price line with a legend, a
  52-week range bar, a nine-cell stats grid, 月營收 and quarterly financials.
- **Every trade has its own page.** Tapping a row opens the record — market,
  date, shares, price, fee, gross, total cost or net proceeds, the realized
  P/L a sell booked, notes, and why the lot reads Open or Closed — with Edit
  and Delete there. A tap used to drop straight into an edit form.
- **The record sheet is one sheet** for trades and dividends, with an explicit
  Taiwan/US control that auto-selects from the ticker, drives the currency and
  the automatic fee, and rejects a symbol that doesn't match its market.
- **AI import** is a four-step modal that flags duplicates and writes nothing
  until the review is confirmed.
- **The assistant** shows a turn in the order it happens — question, tool
  lines, collapsible reasoning, answer — and every write tool lands in a draft
  card that saves nothing until confirmed.

### Fixed
- Charts no longer sit on an automatic y-domain: `AreaMark` anchors its fill at
  zero, which dragged the stock price chart down to 0 and ran the performance
  axis to ±500% while the curves collapsed into the bottom fifth.
- Screens no longer add the design's 60pt top inset *on top of* the safe area.
- **Lists scroll again from anywhere on a row.** The swipe-to-delete gesture was
  exclusive, so it won the drag from the enclosing scroll view the moment a
  finger moved on a row — which is most of a list screen. It now runs
  simultaneously and only claims a drag that is clearly horizontal.
- Quarterly financials show "2026 Q1", not "2026-03-31", and drop rows that
  carry no revenue and no EPS.

## 1.1.0 (build 2) — 2026-07-31

### Design
- **Money formatting split into amounts and prices.** Amounts (P&L, totals,
  dividends, cost basis) no longer carry cents — the dashboard read
  `NT$3,807,168.00` while the overview read `NT$11,611,402`. Prices keep the
  precision they're quoted at.
- **Colour discipline.** One screen previously carried six accents (blue ring,
  cyan "Unrealized", violet "Total return", gold "Dividends", green values,
  orange badge). Colour now has three jobs: accent for interactive, green/red
  only on a P&L *value*, text tokens for every label. Brand hues unchanged.
- **Cinematic Overview.** Lit background with key/fill lights and a vignette;
  the hero figure grew to 52pt, sits directly on that background, and replaces
  the "Portfolios" large title. Today's combined move added — the screen never
  showed it.
- **Chart marks** get slightly deeper stroke colours and a lighter area wash so
  curves sit in the image instead of glowing above it. Values keep brand colours.
- **Chart value scales.** The money charts hid their y-axis, so a curve was
  decorative and scrubbing was the only way to read a value.
- **Settings rebuilt** in the app's card language instead of a stock `Form`;
  developer plumbing (backend URL, OAuth client id, connection test) folded into
  a collapsed "Advanced" section rather than sitting at the same weight as your
  account.
- **Liquid Glass** on the navigation layer only (pinned index bar, settings
  control), with the previous material as the iOS 17 fallback.
- **Market dashboard leads with its total** on the lit background rather than
  boxed in a card with the supporting stats.
- **Market cards** on the Overview grew their value and gained a chevron — they
  navigate, and never signalled it.
- **Assistant**: the API-key prompt was a full-bleed accent bar that read as an
  alert; it's an inset card now, with the accent on the icon. Suggestion chips
  use depth instead of hairline outlines.
- **List separators** (trades, dividends, holdings) softened to half strength
  and inset to the text column — a guide down a long list rather than a grid
  drawn around every row.
- Flag emoji replaced by a drawn market monogram and real titles.
- App version now shown on the splash screen and in Settings.
- Cold start no longer flashes white before the dark splash.

### Fixed
- **Monthly P&L was wrong on every period whose window opened mid-month.** It
  summed a whole calendar month's cash flows while measuring value change over
  only the charted window, so a buy made before the window opened was
  subtracted from a partial month — a 3M window opening Apr 28 reported a
  NT$7,450 April loss that was exactly the size of an Apr 5 purchase. The
  24-month cap also measured its oldest surviving bar against a baseline years
  earlier.
- **Duplicate chart axis labels**, twice: months repeating on short ranges, then
  years repeating on ~2-year spans ("2024, 2025, 2025, 2026"). The axis now
  picks its granularity from the gap between ticks, not the total span.
- Market status line no longer wraps to "Market / closed · 5 / positions".
- Total Return caption no longer collides with its value.

### Added
- **Configurable performance benchmark** — compare against any Yahoo-resolvable
  symbol (an index, a TW ETF by bare code, a US ticker) instead of a hardcoded
  TAIEX/S&P 500. The benchmark legend in the Performance card is the picker.

---

## 1.0 (build 1)

Initial release.
