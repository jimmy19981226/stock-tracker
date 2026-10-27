# Feature reference

Current iOS release: **2.0.13 (build 20)**. Screenshots in the
[gallery](GALLERY.md) use synthetic demonstration records.

### Multi-market overview

- Five persistent tabs: Overview, Trades, Assistant, Dividends, and Settings.
  Trades and Dividends support TW/US filtering; the market drives each record's currency.
- Combined portfolio value in NT$ and an approximate US$ equivalent using the
  available exchange rate. Unrealized P/L and lifetime realized + dividends
  appear separately in the hero.
- **Unified portfolio card:** value, daily change, lifetime figures, and current-year
  earnings share one card, followed by the Add trade and Add dividend actions.
- **Navigation dock:** five visible destinations with larger icons, a full selected
  pill, an opaque surface, and a Reduce Motion-aware fade. It stays above
  the keyboard while composing.
- **Current-year earnings:** distinct realized stock P/L and dividends received
  for TWD and USD. Sales include historical purchase cost and closed positions;
  dividends use payment dates. Future-dated records do not contribute to YTD.
- Configurable indices below “Your portfolio,” cycling every four seconds with
  manual advance and details/editor controls. Common TW/US indices include
  TAIEX, Taiwan OTC, S&P 500, Nasdaq, Dow, SOX, and VIX, subject to feed availability.
  Taiwan OTC uses official TWSE MIS quotes and TPEx monthly history; dated
  closing quotes provide a fallback, and unavailable charts offer Retry.
- Market cards link to Taiwan and United States portfolios. Session labels
  distinguish US pre-market/after-hours from the regular session.
- Light/dark/system appearances, native typography, and configurable Taiwan/US
  P/L color conventions. Directional glyphs provide a non-color signal.

### Market portfolio and performance

- Market-value hero with lifetime realized + dividends, plus today's change
  and unrealized P/L.
- Separate **Holdings** and **Performance** sections. Holdings are searchable
  and sortable, with cost, price, value, P/L, and portfolio weights.
- Taiwan moving-average cost and US FIFO, including recorded fees. Taiwan
  unrealized P/L deducts estimated sale commission and transaction tax; actual
  broker amounts can differ when fee assumptions or recorded data differ.
- Performance metrics, benchmark comparisons, and cumulative earnings history.
  Missing historical prices remain unavailable rather than becoming zero.
- Quotes publish every five seconds while a market is open, with slower closed
  market refreshes. Feed outages/delays remain possible.

### 🔎 Per-stock detail (tap any holding)
- **Live quote header** + key stats: previous close, day range, market cap, P/E, EPS, beta, dividend yield, a visual **52-week range bar**, **1-year analyst target**
- **Your position card**: shares, avg cost, market value, realized + unrealized + dividends + total return (and %)
- **Price-history chart** (1M / 3M / 6M / 1Y / 2Y / 5Y / All) with your buys, sells, and dividends overlaid as markers
- The backend `/detail` endpoint also serves **monthly revenue (月營收)** and **8 quarters of financials** for any ticker — used to enrich AI answers

### ✦ AI assistant
- **One Gemini model on iOS** — Gemini 3.5 Flash-Lite. Included AI uses the backend key; Personal key uses the saved Keychain credential. Switching modes preserves the saved key. Invalid-key errors explain how to recover. Groq/GPT-OSS is not selectable in this version.
- **Typed tool calling** — the model fetches exactly what it needs mid-answer: portfolio summary, holdings, trades, dividends, purchase lots, a sale simulation using the app's own 損益試算 arithmetic, position weights, company fundamentals (including 月營收 and quarterly margins), live quotes for up to 10 tickers at once, price history, TWR/XIRR/benchmark performance, the dividend calendar, net-worth history, the indices *you* follow, USD/TWD, market hours, web search, and a PDF report when the answer is too big for chat. Each call shows a live status line ("Reading holdings…").
- **Dated performance questions** — “How is my performance over these two weeks?” uses a 14-calendar-day window (`2w`) for every market with recorded trades. Custom start/end dates are also supported. Opening/closing values, buys, net sale proceeds, fees and paid dividends determine the period's profit; all-time gains are not substituted. The response identifies actual valuation dates and unavailable historical prices. Short windows fetch only the required price range and skip positions closed before it.
- **It can amend, not just add** — records carry ids, so "that 2330 buy should have been 1,035" produces a **correction**, not a second buy. Corrections, deletions and multi-row imports each get their own confirm card, and a delete card states what the deletion costs — which lots re-open, whose realized P/L moves — computed server-side by replaying the market-specific accounting, never written by the model.
- **Add records by chat** — "I bought 100 shares of 2330 at 1050 today" makes the assistant draft the trade into an in-chat **confirmation card**; nothing is saved until you confirm it. That rule holds for every write the assistant can make, without exception: a write tool returns a proposal, and the record reaches the database through the ordinary endpoint only after you tap.
- **Image-aware chat** — attach a photo (a stock chart, quote, or trade confirmation) right in the compose bar; it stages there so you can still add a note before sending, both go up together, and Gemini reads the image in-conversation. It's told to ask whether it's the US or Taiwan listing when that isn't clear from the image/context, rather than guess — and can still propose the records it reads once the market's confirmed — a whole statement in one card rather than one card per row. Sent images stay tappable full-screen even mid-reply, and persist so reopening the chat later still shows them.
- **Visible reasoning** — Gemini thought summaries, when returned, stream into a collapsible **Reasoning** section (expanded while thinking, collapses when the answer starts, tap to toggle). The iOS model uses minimal thinking to prioritize responsiveness.
- **Background generation** — replies keep generating server-side if you switch apps or lock the screen; the finished answer is waiting when you come back. The stop button cancels the server run too.
- **Progress and recovery** — opening Assistant starts a lightweight prewarm. A reply shows actual tool status, elapsed time, and a stop control. Slow hosting/provider requests can still occur; errors preserve the transcript and offer an editable retry.
- **Readable conversations** — Markdown headings, lists, code, links and tables; two-column metric tables wrap long company names, while wide comparisons scroll horizontally. Copy feedback and editable follow-up prompts accompany answers. Message/progress animations respect Reduce Motion. Keyboard navigation remains available.
- **Portfolio-aware** — chat starts with a small account index. The model requests holdings, records, fundamentals, and calculations through account-scoped tools as needed.
- **Chat history** — past conversations are saved; reopen one, long-press to delete, or clear them all.

### 📄 PDF reports
- **Four reports** — dividend year (TW and US payouts split, gross → tax → net), holdings snapshot, realized P/L & tax summary, and period performance. Export one from **Settings → Reports**, or just ask the assistant for it.
- **Layout lives in a Word template on the server**, not in Swift. The app sends a template id and a period; the backend assembles the JSON and [Adobe Document Generation](https://developer.adobe.com/document-services/apis/document-generation/) renders template + JSON → PDF. A column, a heading or the page furniture changes **without an app release**.
- **The numbers come from the same services the screens read**, so a report can't drift from the app. Taiwan cash dividends carry the 2.11% NHI supplementary premium on each payment of NT$20,000 or more; US dividends use the report service's 30% withholding assumption; every conversion in a document uses one FX rate, captured at generation and printed on the cover.
- **Cached on a key that includes a data version** — re-asking for the same report over unchanged records returns the file that already exists and costs no Document Transaction.
- **Read it in the app** — a full-screen PDFKit viewer with a pager and a share sheet, and the file cached on disk so reopening works offline.
- Adobe credentials live in server environment only (`ADOBE_CLIENT_ID` / `ADOBE_CLIENT_SECRET`); the app talks only to your backend. **Until they're set** — and the four `.docx` templates are dropped in `backend/app/reports/templates/` — the same payload renders locally, so the whole feature works out of the box and Settings tells you which renderer is live.

### 🛠 Trade & dividend management
- Add, edit, and delete **trades** (buy/sell) and **dividends**, with the market as an explicit TW/US control that drives the currency, the automatic fee (TW: max(20, gross × 0.1425%); US: flat 1) and validation — a lettered symbol filed under Taiwan is rejected with a specific message rather than silently guessed
- **Every record has its own page** — market, date, shares, price, fee, gross, total cost or net proceeds, the realized P/L a sell booked, notes, and why the lot reads Open or Closed
- **Paged logs** — the trade and dividend lists page a dozen rows at a time, and the pager keeps the same position on every page
- **Market-specific cost basis** — Taiwan uses moving-average cost, including buy fees, to match broker holdings and realized profit; US positions use FIFO. Trade Open/Closed status tracks shares against the oldest purchases in both markets.
- Backend **CSV import/export** endpoints (one unified file for trades + dividends) and auto-seed from `backend/data/seed/portfolio.xlsx` on first boot
- **AI image import** — snap a brokerage statement/screenshot and a vision model extracts the trades + dividends to review before saving. You can add a **free-text note** alongside the image (e.g. "US trade in USD", "the 優群 row is 3217") that the model uses to disambiguate, and it resolves a Taiwan **company name → stock code** when the document shows only the name.

### 📲 Home Screen widget (iOS)
- Small and medium **WidgetKit** widgets showing combined net worth + today's P&L, with a TW/US breakdown on medium
- Smart-Stack compatible; fed by a shared App Group snapshot the app writes on each refresh (no networking/auth in the extension)

### 🔐 Accounts & data
- **Google sign-in** (login only) via the native OAuth flow — or continue as a guest
- **Per-user data scoping** — each signed-in account sees only its own trades, dividends, and chats; un-authenticated requests fall back to a shared "legacy" bucket

---

[Back to the project overview](../README.md)
