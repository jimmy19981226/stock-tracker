# Handoff: AI Stock Studio — iOS UI redesign

## What's in this bundle
| File | What it is |
| --- | --- |
| `README.md` | This document — the iOS UI redesign spec (tokens, screens, behavior) |
| `ASSISTANT_TOOLS.md` | Assistant tool spec: 6 new tools + 11 upgrades to existing ones, with JSON schemas, repo paths and acceptance criteria |
| `AI Stock Studio App.dc.html` | Interactive design reference for all screens — open in a browser |
| `ADOBE_PDF_REPORTS.md` | PDF reports via Adobe Document Generation: endpoints, templates, the `generate_report` tool, and the two UI entry points |
| `Assistant Tool Spec.dc.html` | The assistant tool spec as a printable document |
| `Assistant Icon Options.dc.html` | Assistant tab icon explorations |

Three workstreams, independent of each other: the UI recreation (this README), the assistant
tool/backend upgrade (`ASSISTANT_TOOLS.md`), and PDF reports (`ADOBE_PDF_REPORTS.md`). The three new confirm cards described in
`ASSISTANT_TOOLS.md` (edit, delete, batch import) follow the card styling defined below.

## Overview
A full visual + interaction redesign of the stock-tracker iOS app (jimmy19981226/stock-tracker), covering
sign-in, Overview (combined net worth), the per-market dashboard, stock detail, Trades, Dividends,
the AI Assistant, AI import, and Settings — plus a complete light/dark theme.

Design language: light technical ground, steel-blue accent, Barlow Condensed numerals over Barlow body
text, grouped white cards with soft elevation, one dark accent field reserved for the net-worth hero.

## About the Design Files
`AI Stock Studio App.dc.html` in this bundle is a **design reference built in HTML** — an interactive
prototype showing intended look, layout and behavior. It is **not** production code to port.
The task is to **recreate these screens in SwiftUI**, inside the existing `ios/StockTracker` app,
using its established views, models and networking. Do not embed the HTML in a WebView.

Open the file in a browser to click through it: tap a market card → dashboard → any holding for detail,
switch chart periods, add/delete trades, run the AI import, chat with the Assistant, toggle
Settings → Appearance for dark mode.

## Fidelity
**High-fidelity.** Colors, type sizes, spacing, corner radii and copy are final. Recreate pixel-closely,
but express everything with SwiftUI-native primitives (`List`/`ScrollView`, `.insetGrouped`-style cards,
SF Symbols, `TabView`) rather than literal HTML translations.

## Design tokens → Swift

Add these to a single `Theme.swift` and reference them everywhere. Both themes must be defined;
the app follows `Appearance` (Light / Dark / System), persisted in `@AppStorage`.

### Color — light
| Token | Hex | Use |
| --- | --- | --- |
| `ground` | #F4F4F6 | screen background |
| `card` | #FFFFFF | card / row background |
| `chrome` | #FFFFFF @ 94% | nav + tab bar background (with `.ultraThinMaterial`) |
| `inset` | #EDEEEF | expanded index-bar rows |
| `track` | #E1E2E4 | segmented-control track, progress track |
| `line` | #E1E2E4 | hairline dividers, 1px |
| `text` | #1D1F20 | primary text |
| `textSecondary` | #6E7A85 | labels, captions |
| `accent` | #5980A6 | selected states, links, chart line |
| `accentTint` | #E7EDF3 | chip / badge fills |
| `accentChipText` | #223649 | text on `accentTint` |
| `heroTop` / `heroBottom` | #1E3348 → #16283C | net-worth hero gradient (160°) |
| `gain` | #3D7A62 | positive P/L |
| `loss` | #A3564E | negative P/L |
| `shadow` | black @ 8% | `y: 1, blur: 3` on cards |

### Color — dark
| Token | Hex |
| --- | --- |
| `ground` | #16273A |
| `card` | #1F3349 |
| `chrome` | #1F3349 @ 94% |
| `inset` | #26405A |
| `track` | #2C4863 |
| `line` | #35526F |
| `text` | #EAF1F8 |
| `textSecondary` | #95AEC9 |
| `accent` | #6F9BC8 (selected tab #7BA5CD) |
| `accentTint` | #264057 |
| `accentChipText` | #A8C6E2 |
| `heroTop` / `heroBottom` | #16283C → #0F1E2E |
| `gain` | #5FA285 |
| `loss` | #C2726A |
| `shadow` | black @ 55% |

**P/L convention is a user setting.** Default US (green = gain). A TW option swaps gain/loss colors —
implement as a single computed `plColor(for:)`, never hard-coded green/red at call sites.

### Type
- **Numerals + headings:** Barlow Condensed SemiBold (600). Bundle the font; register in Info.plist.
- **Body + labels:** Barlow Regular/Medium.
- Scale: hero value 42, screen title 32, section value 30, card value 19–20, row primary 15,
  row secondary 10.5–11, uppercase label 9.5–11 with 0.06–0.14em tracking.
- Never below 10.5pt; tab labels are 10pt.

### Geometry & spacing
- Corner radius: cards 16, hero 18, inset rows/badges 12–14, segmented control 10 (thumb 8),
  buttons 11, sheets 22 (top corners only), pills 8.
- Screen padding 18pt horizontal, 60pt top (under the status bar), 12pt bottom.
- Card padding 14–16pt. Row padding 11–13pt vertical, 14pt horizontal.
- Gaps: 14–16pt between cards, 8–10pt inside stat grids.
- Card shadow: `color: shadow, radius: 3, y: 1`. Hero: `radius: 18, y: 6`, 28% opacity.

## Screens

### 1. Sign-in (`Views/Onboarding`)
Full-bleed 165° hero gradient. ✦ glyph, 40pt title "AI Stock Studio", 14pt subhead in `accentChipText`,
max width 280. Two full-width 46pt buttons: filled white "Continue with Google", outlined
"Continue as guest". Footer 10.5pt: privacy assurance.

### 2. Overview (`Views/Overview`)
- Header row: ✦ AI Stock Studio (11–12pt uppercase, accent) + market session pills (TW / US) —
  `accentTint` fill when the market is open with a `gain` dot, `track` fill when closed with a grey dot.
- **Hero card** (gradient): "Investing net worth" label, 42pt NT$ total, then a 12pt meta row
  (≈ US$ total · USD/TWD rate · clock). Below a hairline, a 4-column stat strip:
  Today / Unrealized / Realized + div / Total return — each with 9pt uppercase label, 13.5pt value,
  9pt sub-line. Values compacted (NT$1.2M, US$42.0K).
- **Net-worth chart card:** title + signed change, then a 6-segment period control (1M 3M 6M YTD 1Y MAX),
  then a line + area chart with 3 dashed gridlines, y-axis labels at left, an end-point dot, and
  from/Today x-labels. Use Swift Charts (`LineMark` + `AreaMark`).
- **Two market cards** (Taiwan, US), each tappable → dashboard: code chip, title, "n% of total",
  chevron; 30pt market value + session note; four label/value rows (Today, Unrealized, Realized,
  Dividends) with signed values and a secondary percent; a divider then "Total return · CUR" with
  value + percent.
- Footer caption: "Updated HH:MM:SS · TW open · auto-refresh 5 s".

### 3. Market dashboard (`Views/Portfolio/DashboardView`)
Back row (chevron + "Overview") + session pill. 32pt market title + hours caption.
- **Hero:** "Total earned — realized + dividends" + 38pt value; divider; "Total return incl. unrealized".
- **2×3 stat grid:** Market value, Today, Unrealized P/L, Realized P/L, Dividends, Cost basis —
  each card carries label, 19pt value, and a caption ("net of exit costs · +12.4%", "FIFO", "open lots").
- **Total-earned chart:** 4 periods (1M 3M 1Y MAX), same chart treatment, y-axis 0 → max.
- **Performance card:** 5 periods (3M 6M YTD 1Y MAX); three stats (Return TWR, Annualized,
  vs benchmark); a legend where the benchmark name is tappable to cycle
  (TW: 加權指數 / 櫃買指數 / 元大台灣50 — US: S&P 500 / NASDAQ / Dow Jones); a two-line chart
  (portfolio 2.2pt accent, benchmark 1.4pt grey) with right-side % axis; then a 12-bar
  monthly-P&L row, gain/loss colored, with month labels.
- **Holdings list:** header row (Ticker / Price / Unrealized) + sort control (Value, Today, Gain %).
  Each row: ticker + name, "300 sh · avg 985.00 · 50.4%", a 3pt weight bar; right column price,
  today %, compacted market value; far-right unrealized value + percent. Tap → stock detail.
- Footer: the exit-cost note.

### 4. Stock detail (`Views/StockDetail`)
Back row + data-source pill (TWSE MIS · live / Yahoo · 15 m delayed). Name + code, 38pt price,
signed change. 7 periods (1M 3M 6M 1Y 2Y 5Y All). Chart with area fill plus **trade markers**:
up triangle = buy (gain color), down triangle = sell (loss color), hollow circle = dividend, with a legend.
Then: "Your position" card (2×3: shares·avg cost, market value, unrealized net, dividends, realized,
total return); a 52-week range bar with a position tick and low/current/high labels; a 3-column
stats grid (9 cells: prev close, day range, mkt cap, P/E, EPS, yield, beta, target, vs now — ETFs
instead show AUM, expense, holdings, next ex-div, frequency); for TW stocks a **月營收** card
(12 monthly bars + latest value with YoY) and an 8-quarter **financials table**
(quarter, revenue, EPS, gross margin — green when improving QoQ, operating margin);
finally a "Your records" list of that ticker's trades and dividends.

### 5. Trades (`Views/Trades`)
Title + "+ Add trade"; "⌗ AI import" in the header. Two filter controls: market (All/TW/US) and
status (All/Open/Closed). Count + "n buys · n sells". Rows: BUY/SELL tag, ticker + name,
"1,000 × 98.00 · fee 140 · NT$98,000", realized-P/L line when closed, date + Open/Closed,
delete button. Footer explains FIFO. Swipe-to-delete is the SwiftUI-native equivalent of the ✕ button.

### 6. Add trade / dividend sheet
Bottom sheet, 22pt top radius. BUY/SELL segmented control (trades only).
**Market is explicit:** a Taiwan · TWD / US · USD segmented control at the top, auto-selected as the
user types (all-digit code → TW, letters → US, a known ticker matches by name) and always overridable;
a hint line reports what was matched. The market drives currency labels, the auto fee
(TW: max(20, gross × 0.1425%); US: flat 1) and validation — a TW market with a lettered symbol
(or vice-versa) is rejected with a specific message rather than silently guessed.
Fields: Ticker, Date, Shares, Price/Amount, Fee (auto), Notes. A meta row shows the market's fee rule
and the gross total. Save shows a toast ("Buy added · lot open · Taiwan").

### 7. Dividends (`Views/Dividends`)
Three stat cards (Taiwan received, US received, next-90-day estimate). **Dividend calendar** —
upcoming rows with an accent day/month date badge, ticker + name, "Ex-div date · pays date · rate/sh",
and an estimated amount marked "est.". Then a "Received" list with a hollow-circle marker,
ticker + name, "date · 現金股利 13.0/股", amount, delete.

### 8. Assistant (`Views/Assistant`)
Header: history button, "✦ Assistant", provider pill, new-chat button.
Empty state: "Try asking" + 4 suggestion buttons + a note listing the 14 tools.
Message types, in order of a turn:
1. **User bubble** — accent fill, white text, radius 18/18/5/18, right-aligned, max 80%.
2. **Tool-status lines** — 11.5pt secondary with a small accent dot ("get_portfolio_summary · reading holdings…").
3. **Reasoning block** — `track` fill, radius 14, collapsible header with a rotating chevron and a duration;
   streams while thinking, then auto-collapses. Visibility follows the "Show reasoning" setting.
4. **Answer** — serif body (Georgia in the prototype; use a serif face or the body font), streamed at
   ~190 chars/s, optionally followed by a 3-column table, source chips, and a
   "not investment advice" caption.
5. **Draft-trade card** — when the user says "I bought 2,000 shares of 00919 at 24.6 today", the
   assistant returns a confirm card (ticker / shares @ price / date · fee) with **Add trade** and
   **Discard**. Nothing is written until confirmed — keep this rule for every write tool.
While generating, show "✦ generating — continues if you leave the app" with a **Stop** button.

### 9. AI import (`Views/Import`)
Full-screen modal, 4 steps: (0) dashed drop card "Snap a brokerage statement" + note field,
(1) parsing state with a pulsing title and a checklist ("✓ Resolving 長榮 → 2603"),
(2) review list of parsed records with tags, flagging duplicates, + "Add all n records",
(3) success. Nothing saves before step 2 is confirmed.

### 10. Settings (`Views/Settings`)
Grouped sections: **Account** (avatar, email, sign out) · **Appearance** (Light / Dark / System +
a note reporting the resolved mode) · **AI assistant** (provider segmented OpenAI/Gemini/Claude,
API-key secure field, "Show reasoning" and "Keep generating in background" switches) ·
**Backend** (URL field + health / relay / database / last-export rows with status dots) ·
**Markets & indices** (hours + open state per market, followed-index
count with Edit) · **About** (version, data sources, Privacy & disclosures → full-screen text).
Footer: "no analytics, no telemetry · Not investment advice."

### 11. Market index bar
Pinned above the tab bar on Overview screens. Collapsed: a horizontally scrolling row of
name + value + signed percent, a ＋ to add, and a chevron to expand. Expanded: one `inset` card per
index with name, symbol, 19pt value, signed change, O/H/L, and a 1-month sparkline.
An editor sheet reorders/removes followed indices and offers suggestions.

### 12. Tab bar
Five tabs: Overview, Trades, Assistant, Dividends, Settings. 25pt icons, **filled glyph + 600 weight
label when selected, 1.7pt outline + regular when not**; selected accent, unselected `textSecondary`;
background `chrome` over `.ultraThinMaterial` with a hairline top border.
SF Symbols equivalents: `house.fill`/`house`, `arrow.left.arrow.right`,
`sparkles` (the chosen Assistant glyph — a two-size sparkle pair), `dollarsign.circle.fill`/`dollarsign.circle`,
`slider.horizontal.3`.

## Interactions & behavior
- **Live quotes:** poll every 5 s while a market is open; freeze at last close when shut.
  Every derived number (net worth, P/L, holdings, charts) recomputes from the same tick.
  Prototype jitters prices locally to demonstrate this — replace with the real quote service.
- Navigation: Overview → market dashboard → stock detail, back via chevron.
- All period/sort/filter/benchmark controls change data instantly, no spinner.
- Toasts: 12.5pt white on 92% black, radius 12, ~2.2 s, above the tab bar.
- Deletes are immediate + toast (use swipe-to-delete in SwiftUI).
- Streaming answers must survive leaving the screen when "Keep generating" is on.

## Numbers — must match the backend exactly
- **Unrealized P/L is net of estimated exit costs**: TW = value × (0.1425% + transaction tax;
  0.3% stocks, 0.1% ETFs). This is what makes it agree with broker 損益試算 — keep it.
- **Realized P/L is FIFO**: a sell consumes oldest lots first; a buy lot with shares remaining is Open.
- **Total earned** = realized + dividends. **Total return** = total earned + unrealized.
- Combined net worth converts US at the cached FX rate; show the rate and its age.
- Percent formatting: signed with an explicit − (U+2212), 2 dp for daily moves, 1 dp for returns.
  Large money compacts to K/M/B.

## State
`appearance`, `plConvention`, `aiProvider`, `apiKey` (Keychain), `showReasoning`, `backgroundGeneration`,
`backendURL`, `followedIndices` — all persisted. Per-screen: selected market, selected ticker,
holdings sort, and the four chart period selections (net worth, total earned, performance, stock),
which are independent of one another.

## Assets
No image assets. All icons are vector glyphs — use SF Symbols in SwiftUI.
Fonts: Barlow + Barlow Condensed (Google Fonts, OFL) must be bundled.

## Files in this bundle
- `AI Stock Studio App.dc.html` — the full interactive prototype (all screens, both themes).
- `Assistant Icon Options.dc.html` — the Assistant tab-icon candidates; option A (sparkles pair) was chosen.
- `ios-frame.jsx`, `support.js`, `_ds/` — supporting runtime + design tokens so the prototype opens offline.

## Repo mapping
See `github.md` in the project root for the screen → source-file map
(`ios/StockTracker/Views/...` and the `/api/...` endpoints each screen reads).
