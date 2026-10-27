# Feature reference

### 🌏 Multi-market overview (TW + US)
- **Two portfolios, one app** — Taiwan (TWD) and US (USD) holdings each get their own dashboard, while Trades and Dividends are single screens across both markets with a TW/US filter. Market is auto-detected from the ticker format (numeric → TW, letters → US) and is always an explicit, overridable control on the record form.
- **Overview landing page** — a TW card and a US card showing each market's value, total P/L, and today's move. Tap a card to enter that portfolio; the back button returns you to the overview.
- **Combined net worth** — both portfolios summed into a single figure shown in **both NT$ and US$**, with the live USD↔TWD rate. The number flashes green/red as it ticks.
- **Combined unrealized P&L** — the Overview also shows unrealized P&L alone (open positions' gain/loss, US converted to NT$ at the live rate) alongside the all-in Total Return figure, so you can see them separately.
- **Color-coded P&L** — gains render green, losses red, across the net worth, market cards, summary, and every holding.
- **US pre-market / after-hours status** — the US market card shows "Pre-Market" / "After Hours" during NYSE/Nasdaq's real extended sessions (an amber dot, distinct from the green "Market open"), instead of collapsing straight to "Market closed". Taiwan cash equities have no analogous evening session, so the TW card stays open/closed only.
- **DB-driven market config** — trading hours, holidays, currency, and timezone for each market live in the database (`markets` + `market_holidays` tables), not hardcoded, so the open/closed status is correct per market and editable without a redeploy.

### 📊 Live portfolio dashboard
- Hero **Total Earned** card (realized + dividends) with gradient styling
- **Total Return** card — realized + dividends + unrealized, your all-in profit
- Per-currency summary grid: market value, unrealized P/L, realized P/L, dividends, and today's move (accent-colored)
- Unrealized P/L is **net of estimated exit costs** (sell commission + transaction tax), so it matches your broker's 損益試算 / 獲利率 rather than the gross gain
- **Cumulative earnings chart** (Swift Charts) stacking realized P/L + dividends
- **Performance card** — time-weighted return, annualized, and the gap against the market's benchmark index, with the two curves overlaid and twelve months of P&L underneath. Tap the benchmark name to compare against a different index.
- **Holdings list** — each position with shares, avg cost, live price, today's move, market value and unrealized P&L, plus a weight bar showing its share of the market; sortable by value, today's move, or gain %

Holdings/summary refresh while a portfolio is on screen — every 5 s while that market is open, 60 s otherwise.

### 🔎 Per-stock detail (tap any holding)
- **Live quote header** + key stats: previous close, day range, market cap, P/E, EPS, beta, dividend yield, a visual **52-week range bar**, **1-year analyst target**
- **Your position card**: shares, avg cost, market value, realized + unrealized + dividends + total return (and %)
- **Price-history chart** (1M / 3M / 6M / 1Y / 2Y / 5Y / All) with your buys, sells, and dividends overlaid as markers
- The backend `/detail` endpoint also serves **monthly revenue (月營收)** and **8 quarters of financials** for any ticker — used to enrich AI answers

### ✦ AI assistant
- **One Gemini model on iOS** — Gemini 3.5 Flash-Lite with **your own API key** (entered in-app, stored in the iOS Keychain, sent per-request — never stored on the server). The existing Gemini key is retained; old provider and model selections are ignored.
- **Typed tool calling** — the model fetches exactly what it needs mid-answer: portfolio summary, holdings, trades, dividends, purchase lots, a sale simulation using the app's own 損益試算 arithmetic, position weights, company fundamentals (including 月營收 and quarterly margins), live quotes for up to 10 tickers at once, price history, TWR/XIRR/benchmark performance, the dividend calendar, net-worth history, the indices *you* follow, USD/TWD, market hours, web search, and a PDF report when the answer is too big for chat. Each call shows a live status line ("Reading holdings…").
- **Dated performance questions** — “How is my performance over these two weeks?” uses a 14-calendar-day window (`2w`) for every market with recorded trades. Custom start/end dates are also supported. Opening/closing values, buys, net sale proceeds, fees and paid dividends determine the period's profit; all-time gains are not substituted. The response identifies actual valuation dates and unavailable historical prices. Short windows fetch only the required price range and skip positions closed before it.
- **It can amend, not just add** — records carry ids, so "that 2330 buy should have been 1,035" produces a **correction**, not a second buy. Corrections, deletions and multi-row imports each get their own confirm card, and a delete card states what the deletion costs — which lots re-open, whose realized P/L moves — computed server-side by replaying the market-specific accounting, never written by the model.
- **Add records by chat** — "I bought 100 shares of 2330 at 1050 today" makes the assistant draft the trade into an in-chat **confirmation card**; nothing is saved until you confirm it. That rule holds for every write the assistant can make, without exception: a write tool returns a proposal, and the record reaches the database through the ordinary endpoint only after you tap.
- **Image-aware chat** — attach a photo (a stock chart, quote, or trade confirmation) right in the compose bar; it stages there so you can still add a note before sending, both go up together, and Gemini reads the image in-conversation. It's told to ask whether it's the US or Taiwan listing when that isn't clear from the image/context, rather than guess — and can still propose the records it reads once the market's confirmed — a whole statement in one card rather than one card per row. Sent images stay tappable full-screen even mid-reply, and persist so reopening the chat later still shows them.
- **Visible reasoning** — Gemini thought summaries, when returned, stream into a collapsible **Reasoning** section (expanded while thinking, collapses when the answer starts, tap to toggle). The iOS model uses minimal thinking to prioritize responsiveness.
- **Background generation** — replies keep generating server-side if you switch apps or lock the screen; the finished answer is waiting when you come back. The stop button cancels the server run too.
- **Always ready** — opening the Assistant pre-warms the backend and pre-builds your portfolio context, so the first message streams immediately.
- **Streaming replies** rendered as Markdown in the app's own reading voice — headings, bold, lists, code blocks, blockquotes, tables — with the tool lines above them and the "not investment advice" note below.
- **Portfolio-aware** — every chat carries a snapshot of your holdings + light fundamentals; mention a ticker and its monthly revenue + quarterly margins are attached so the model answers with real numbers.
- **Chat history** — past conversations are saved; reopen one, long-press to delete, or clear them all.

### 📄 PDF reports
- **Four reports** — dividend year (TW and US payouts split, gross → tax → net), holdings snapshot, realized P/L & tax summary, and period performance. Export one from **Settings → Reports**, or just ask the assistant for it.
- **Layout lives in a Word template on the server**, not in Swift. The app sends a template id and a period; the backend assembles the JSON and [Adobe Document Generation](https://developer.adobe.com/document-services/apis/document-generation/) renders template + JSON → PDF. A column, a heading or the page furniture changes **without an app release**.
- **The numbers come from the same services the screens read**, so a report can't drift from the app. Taiwan cash dividends carry the 2.11% NHI supplementary premium on each payment of NT$20,000 or more; US dividends are shown withheld at the 30% statutory rate; every conversion in a document uses one FX rate, captured at generation and printed on the cover.
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
