# AI Stock Studio — iOS changelog

The version shown on the splash screen comes from `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` in [`project.yml`](project.yml), read back at runtime
via `AppConfig.versionDisplay`. There is no second place to edit.

**Releasing:** bump both values in `project.yml`, add an entry at the top of
this file, run `xcodegen generate`, then build. Marketing version is
`MAJOR.MINOR.PATCH`; the build number increments on every build you install
anywhere, even for the same marketing version.

---

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
