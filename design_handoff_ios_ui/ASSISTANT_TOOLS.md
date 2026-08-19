# Handoff: Assistant tool surface v2 + confirm cards

**Target repo:** `jimmy19981226/stock-tracker` (branch `main`)
**Primary files you will touch:** `backend/app/services/ai_tools.py`, `backend/app/routers/ai.py`, `ios/StockTracker/Views/Assistant/AssistantView.swift`
**Read first, do not re-derive:** `ios/StockTracker/Theme/Theme.swift`, `ios/StockTracker/Util/Format.swift`, `ios/StockTracker/Views/Components/Components.swift`

---

## 1. What this is

Two pieces of work, one behind the other:

1. **Backend** — add 6 tools to the assistant's tool surface and change 11 of the existing 14. Additive; no existing call signature breaks.
2. **iOS** — add 3 confirm-card variants to the Assistant chat (edit, delete, batch) so the new write tools have a UI. The add card already exists and is not changed.

Ship §3 (record identity) and §4 (update/delete) first. They fix a defect. Everything after that is an improvement.

### About the design files in this bundle

`AI Stock Studio App.dc.html` and `Assistant Tool Spec.dc.html` are **design references written in HTML** — they are not production code and nothing in them should be copied verbatim. The HTML app file is a high-fidelity recreation of the shipping SwiftUI app (built by reading the repo's own view source), included so you can see the intended layout, spacing, colour and copy of every screen including the Assistant. Implement in **SwiftUI**, using the app's existing `Theme`, `Fmt` and `Components` — never new tokens, never a hardcoded hex.

**Fidelity: high.** Colours, type, radii and spacing in this document are exact and come from `Theme.swift`. Match them.

---

## 2. Current state (verified by reading `ai_tools.py`)

14 tools registered in `TOOLS`. 12 read, 2 write.

| | Tools |
|---|---|
| Read | `get_portfolio_summary`, `get_holdings`, `get_trades`, `get_dividends`, `get_quote`, `get_price_history`, `get_performance`, `get_dividend_calendar`, `get_net_worth_history`, `get_fx_rate`, `get_market_status`, `search_web` |
| Write | `add_trade`, `add_dividend` |

Loop constants: `MAX_TOOL_ROUNDS = 6`, `_RESULT_CAP = 8000` (chars, applied uniformly).

Write contract, already implemented and **to be preserved exactly**: a write tool never touches the database. It returns a proposed-action payload; the iOS client renders a confirm card; on tap the client calls the ordinary REST endpoint (`POST /trades`, `POST /dividends`). Payload shape today:

```json
{ "trades": [ { … } ], "dividends": [ { … } ] }
```

---

## 3. Blocking defect: records have no identity

`get_trades` returns `type, ticker, shares, price, date, fee, market, status, notes` — **no `id`**. The model can read a trade and cannot afterwards refer to it. The only write it has is `add_trade`. So:

> User: "That 2330 buy should have been 1,035, not 1,053."
> Assistant: reads the trade, then proposes **a new trade**, because that is the only write available.

The user now holds two buys instead of one corrected buy, and FIFO status, cost basis and every unrealized figure downstream are wrong.

### 3.1 Change

Add `id: int` to every row returned by `get_trades` and `get_dividends`. No other change. This is the prerequisite for §4 and is worth deploying on its own.

---

## 4. New write tools

All four follow the existing contract: **propose only, never persist.**

### 4.1 `update_trade` / `update_dividend`

Input: the `id`, plus **only** the fields that change.

```json
{
  "name": "update_trade",
  "input_schema": {
    "type": "object",
    "required": ["id"],
    "properties": {
      "id":     { "type": "integer" },
      "type":   { "type": "string", "enum": ["buy", "sell"] },
      "ticker": { "type": "string" },
      "shares": { "type": "number", "exclusiveMinimum": 0 },
      "price":  { "type": "number", "exclusiveMinimum": 0 },
      "date":   { "type": "string", "description": "YYYY-MM-DD" },
      "fee":    { "type": "number", "minimum": 0 },
      "market": { "type": "string", "enum": ["TW", "US"] },
      "notes":  { "type": "string" }
    },
    "additionalProperties": false
  }
}
```

Server behaviour: load the record by id, reject with a plain-language error if it does not exist or belongs to another user, then emit an action row carrying **both** the stored values and the proposed values so the card can render a before → after diff without a second fetch:

```json
{ "trades": [ {
    "op": "update", "id": 3,
    "before": { "price": 1053, "fee": 150 },
    "after":  { "price": 1035, "fee": 148 },
    "record": { "ticker": "2330", "type": "buy", "shares": 100, "date": "2026-03-06", "market": "TW" }
} ] }
```

`before`/`after` contain **only changed fields**. `record` is the unchanged identifying context for the card header.

### 4.2 `delete_trade` / `delete_dividend`

Input: `{ "id": integer }` only.

Emit the **full** record plus any consequence the client must warn about:

```json
{ "trades": [ {
    "op": "delete", "id": 3,
    "record": { "ticker": "2330", "type": "buy", "shares": 100, "price": 1035,
                "date": "2026-03-06", "fee": 148, "market": "TW" },
    "consequences": ["Deleting this buy re-opens the 2330 sell of 2026-05-11 (FIFO)."]
} ] }
```

Compute `consequences` server-side by re-running the FIFO pass without the record and diffing lot status. Empty array when nothing else changes. **Do not** let the model author this string.

### 4.3 `propose_records` — replaces `add_trade` / `add_dividend`

One call proposes any number of records of either kind. The action payload is already an array-of-arrays shape, but `add_trade` only ever fills one slot — so a statement photo with eight fills costs eight calls against a 6-round ceiling and gives the user eight cards to tap.

```json
{
  "name": "propose_records",
  "input_schema": {
    "type": "object",
    "properties": {
      "trades":    { "type": "array", "maxItems": 50, "items": { "$ref": "#/$defs/trade" } },
      "dividends": { "type": "array", "maxItems": 50, "items": { "$ref": "#/$defs/dividend" } },
      "summary":   { "type": "string", "description": "One line for the card header, e.g. '3 buys and 1 sell, Aug 2026'" }
    }
  }
}
```

Each item carries `op` (`"create" | "update" | "delete"`, default `"create"`), so one call can mix a correction into an import.

Server adds, per proposed create, a `duplicate_of: int | null` — set when an existing record matches ticker + date + shares + price. The card uses it to pre-flag rows.

**Migration:** keep `add_trade` and `add_dividend` registered and working for one release so a model mid-conversation does not break, then remove them from `TOOLS`.

### 4.4 Payload compatibility

`op` defaults to `"create"` and `before`/`after`/`consequences`/`duplicate_of` are all optional. Today's iOS confirm card must keep parsing today's payloads unchanged — verify this before shipping the backend, because the backend deploys ahead of the App Store build.

---

## 5. New read tools

| Tool | Input | Returns | Notes |
|---|---|---|---|
| `get_stock_info` | `ticker`, `include: ["profile","revenue","financials"]` | Sector, market cap, P/E, fwd P/E, EPS, yield, beta, P/B, avg volume, 52-week high/low; 12 months of 月營收 with YoY; 8 quarters of revenue + gross margin | Wrap the **same** service the Stock detail screen uses (`services/stock_info.py`). Today "is 2330's gross margin improving?" falls through to `search_web` when the answer is already in the DB. |
| `get_lots` | `ticker?`, `market?`, `open_only?` | Per lot: `id`, buy date, shares bought, shares remaining, unit cost, days held | `get_trades` reports open/closed but never the arithmetic under it. Without this the model reconstructs FIFO from raw trades and gets partial fills wrong. |
| `simulate_sale` | `ticker`, `shares`, `price` | Lots consumed FIFO, gross proceeds, commission, transaction tax, net proceeds, realized P/L, resulting remaining position | **Must call the app's own 損益試算 code path.** Commission 0.1425%; transaction tax 0.3% for a stock and **0.1% for an ETF** — a model deriving this itself will eventually disagree with the number on screen, and the screen is what the user trusts. |
| `get_allocation` | `market?`, `group_by: "ticker" \| "sector"` | Weight of each position as a share of its market and of net worth, sorted desc, with a `top_n` and an aggregated tail | Weights, not totals — `get_portfolio_summary` already gives per-currency sums. This is the Dashboard donut. |
| `get_followed_indices` | — | Each followed index: symbol, display name, market, latest price, change, change % | "Am I beating the market" must mean the indices **this user** follows. `get_performance` compares against one and the model cannot discover which. |

---

## 6. Changes to the existing 14

| Tool | Change | Reason |
|---|---|---|
| `get_quote` | Accept `tickers: string[]` (cap 10). Keep single `ticker` as an alias. | Five tickers costs five of six rounds; the loop can end before the answer does. |
| `get_trades` | Return `id`. Add `year: int` and `type: "buy"\|"sell"` filters. Add `realized_pl` on closed sells. | Identity for §4; parity with the Trades screen's year filter; realized P/L is asked for constantly and is otherwise derivable only from the whole ledger. |
| `get_dividends` | Return `id`. Add a `market` filter. | `get_trades` takes `market` and this does not — the asymmetry makes the model fetch everything and filter in prose. |
| `get_portfolio_summary` | Add a `market` filter. Include the `usd_twd` rate used in the response. | Every combined figure depends on a rate the model otherwise fetches separately and may quote stale. |
| `get_price_history` | Accept up to 3 tickers. Add `interval: "1d"\|"1wk"\|"1mo"`. | Relative-performance questions are inherently multi-series; weekly bars over 5 years survive the result cap far better than daily. |
| `get_dividend_calendar` | Split totals per currency explicitly. Mark every projected row `estimated: true`. | A projection presented like a receipt is the one error here a user would act on. Estimates are `per_share × shares_held` (see `services/income.py`) — label them as such. |
| `get_market_status` | Include `next_open` and `next_close` as ISO 8601 timestamps. | "Closed" alone makes the model guess when trading resumes, and it guesses wrong across holidays. |
| `search_web` | For a numeric TW code, append the company name to the query server-side. | The tool description currently asks the model to remember this; the code can guarantee it. A bare "2330" query returns noise. |
| `add_trade` | Accept an explicit `market`. | The iOS form requires market; the tool infers it. Inference holds until a user owns a ticker that reads as both. |
| `MAX_TOOL_ROUNDS` | 6 → 8, **after** batching lands. | A grounded multi-market answer legitimately needs summary + holdings + 2 histories + FX + search. |
| `_RESULT_CAP` | Replace the uniform 8,000 with per-tool caps; truncate **series** by downsampling, never by cutting the string. | A truncated JSON series is worse than a short one — the model reads the fragment as the whole and reports a false trend. |

---

## 7. iOS: the three new confirm cards

Add to `AssistantView.swift` alongside the existing add card. All three are `Theme.card`-backed, `Theme.Radius.card` = 16, `Theme.Space.l` = 14 padding, and use `Fmt` for every number. The existing card's structure — header row, body, footer line, action row — is reused; only the body differs.

**Rules that apply to all three:**
- The footer line `"Nothing is saved until you confirm"` stays on every write card.
- Primary action states its consequence in words. Never "Confirm" or "OK".
- Numbers use `Fmt` only: U+2212 for minus, `US$` (not `$`) for USD, amounts drop cents in TWD and keep them in USD, prices always 2 dp.

### 7.1 Edit card

- Header: `TagChip` with the record type (BUY/SELL/DIV) + ticker + company name, exactly as the trade row renders it.
- Body: one row **per changed field only**. Field label in `Theme.Typo.caption` / `textSecondary`; old value struck through in `textTertiary`; arrow `→`; new value in `Theme.Typo.numberM` / `text`.
- Never re-summarise unchanged fields. The user needs to see what moves, not re-read what does not.
- Actions: `Save change` (accent) · `Discard`.

### 7.2 Delete card

- Body: the record in **full**, same layout as `TradeRecordView`'s detail grid.
- Any `consequences` string renders **above** the action row, in `Theme.Typo.footnote` on `Theme.loss`-tinted background at 12% opacity, radius `Theme.Radius.inset` = 14.
- Primary action names the object: **`Delete this trade`** / `Delete this dividend`. Tinted `Theme.loss`.
- This is the one card where the destructive action is **not** the default focus — `Keep it` sits first in the row.

### 7.3 Batch card

- Reuse the **existing** `ImportRecordsView` row component verbatim — per-row include toggle, duplicate flag, market chip. Do not build a second one.
- Header: the tool's `summary` string.
- Rows with `duplicate_of != nil` default to **excluded** and show `Possible duplicate · Aug 6` in `Theme.loss`.
- Primary action carries the live count: `Add 4 records` — recomputed as toggles change, disabled at 0.

---

## 8. Design tokens (from `Theme.swift` — do not invent)

Light / dark:

| Token | Light | Dark |
|---|---|---|
| ground | `#F4F4F6` | `#16273A` |
| card | `#FFFFFF` | `#1F3349` |
| inset | `#EDEEEF` | `#26405A` |
| track | `#E1E2E4` | `#2C4863` |
| line | `#E1E2E4` | `#35526F` |
| text | `#1D1F20` | `#EAF1F8` |
| textSecondary | `#6E7A85` | `#95AEC9` |
| textStrong | `#4A555F` | `#B5C9DE` |
| textTertiary | `#9AA4AD` | `#6D89A8` |
| accent | `#5980A6` | `#6F9BC8` |
| accentTint | `#E7EDF3` | `#264057` |
| accentChipText | `#223649` | `#A8C6E2` |
| gain | `#3D7A62` | `#5FA285` |
| loss | `#A3564E` | `#C2726A` |

**Gain/loss are convention-dependent.** The Settings toggle swaps `gain` and `loss` for the TW convention (red = up). Read them through `Theme.gain` / `Theme.loss`, never as literals.

Radius: card 16 · hero 18 · inset 14 · badge 12 · segment 10 (thumb 8) · button 11 · sheet 22 · pill 8
Space: xxs 4 · xs 6 · s 8 · m 10 · l 14 · xl 16 · xxl 18 · screen H 18 · card gap 16 · grid gap 10
Type: Barlow Condensed SemiBold for numerals and headings; Barlow Regular/Medium for prose. Slide/label caps carry 1.32–1.68pt tracking.

---

## 9. Acceptance criteria

Backend:
1. `get_trades` and `get_dividends` return `id` on every row.
2. A correction request produces **one** `update_trade` proposal, not an `add_trade`.
3. A delete proposal for a buy consumed by a later sell includes a non-empty `consequences`.
4. `propose_records` handles 12 rows in one call, flagging duplicates.
5. `simulate_sale` on an ETF applies 0.1% transaction tax; on a stock, 0.3%. Both match the app's 損益試算 to the last unit.
6. A payload with no `op` field still parses and still means create.
7. `get_quote` with 5 tickers is one round, not five.

iOS:
8. The edit card lists changed fields only.
9. The delete card's primary action reads "Delete this trade" and is not the default focus.
10. The batch card's button count tracks the toggles.
11. Every write card still shows "Nothing is saved until you confirm".
12. No new colour literals; flipping the Settings gain/loss convention recolours all three cards.

---

## 10. Order of work

| Step | Ship | Unlocks |
|---|---|---|
| 1 | `id` on both read tools | Prerequisite for every write below |
| 2 | `update_*` / `delete_*` + edit & delete cards | **Corrections.** The largest gap in the product |
| 3 | `propose_records` + batch card | A statement photo becomes a month of records in one tap |
| 4 | `get_stock_info` | Fundamentals answered from your data, not the open web |
| 5 | `get_lots`, `simulate_sale` | Sell-side questions with the app's own cost and tax arithmetic |
| 6 | Batched quotes/history, filters, loop limits | Fewer rounds, less truncation, no stale FX |
| 7 | `get_allocation`, `get_followed_indices` | Concentration and benchmark questions |

Steps 1–2 are worth deploying alone. Until they land the assistant is a reader that can add but not amend — and a tool that can only ever add is how a portfolio quietly fills with duplicates.

---

## 11. Files in this bundle

| File | What it is |
|---|---|
| `README.md` | This document. Self-sufficient — implement from it. |
| `Assistant Tool Spec.dc.html` | The same spec as a formatted, printable page. Reference only. |
| `AI Stock Studio App.dc.html` | High-fidelity HTML recreation of the whole shipping app, including the Assistant tab and the existing add-confirm card. Open in a browser to see intended layout, copy and behaviour. **Design reference — not code to port.** |
| `doc-page.js` | Support file for the printable spec. Ignore. |
