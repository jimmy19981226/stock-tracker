<div align="center">

# ✦ AI Stock Studio

A self-hosted **multi-market equities workbench** for **Taiwan + US** portfolios — live prices, broker-matching P/L, per-stock fundamentals, monthly revenue, quarterly financials, a **combined net-worth overview** across both markets (NT$ and US$), live-value flash animations, and a streaming, **agentic** AI assistant that searches the web, cites every claim, analyzes your portfolio, and can even **drive the UI for you**.

</div>

![Dashboard](docs/screenshots/dashboard.png)

> Built because every off-the-shelf portfolio tracker either ignores
> dividends, charges money, or sends your trade history to a third party.
> This one runs on your laptop, stores everything in a local SQLite file
> (or your own Neon Postgres), and only pulls public market data — TWSE MIS
> for Taiwan, Yahoo for US — with no broker login. The AI assistant is opt-in
> and gated by your own key.

---

## 📱 Native iOS app

A native **SwiftUI** iPhone app (in [`ios/`](ios/)) talks to the same FastAPI backend — bottom tab bar, dark "studio" theme, Swift Charts, an animated splash, Google sign-in, multi-provider AI (OpenAI / Gemini / Claude with your own key), **Claude-style Markdown** in the assistant, and per-user data scoping. Build the sideloadable `.ipa` with [`ios/rebuild-ipa.sh`](ios/rebuild-ipa.sh) and install it permanently via SideStore — see the [install guide](ios/INSTALL_ON_IPHONE.md).

<div align="center">
<img src="docs/screenshots/ios-overview.png" width="240" alt="Net-worth overview" />
&nbsp;
<img src="docs/screenshots/ios-dashboard.png" width="240" alt="Portfolio dashboard" />
&nbsp;
<img src="docs/screenshots/ios-assistant.png" width="240" alt="AI assistant" />
</div>

---

## What's inside

### 🌏 Multi-market overview (TW + US)
- **Two portfolios, one app** — Taiwan (TWD) and US (USD) holdings are tracked separately, each with their own dashboard, trades, and dividends. Market is detected from the ticker format (numeric → TW, letters → US).
- **Overview landing page** — a TW card and a US card showing each market's value, total P/L, today's move, and total earned. Click a card to enter that portfolio; a back button + market chip return you to the overview.
- **Combined net worth** — both portfolios summed into a single figure shown in **both NT$ and US$**, with the live USD↔TWD rate. The number flashes green/red as it ticks.
- **Live-value flash** — every price-driven number (combined net worth, each market total, the in-portfolio summary cards, and individual holding price/value) flashes green on an uptick, red on a down-tick.
- **DB-driven market config** — trading hours, holidays, currency, and timezone for each market live in the database (`markets` + `market_holidays` tables), not hardcoded, so the open/closed status is correct per market and editable without a redeploy.

### 📊 Live portfolio dashboard
- Hero **Total Earned** card (realized + dividends) with gradient styling
- **Total Return** card — realized + dividends + unrealized, your all-in profit
- Per-currency summary grid: market value, unrealized P/L, realized P/L, dividends, and today's move (accent-colored)
- Unrealized P/L is **net of estimated exit costs** (sell commission + transaction tax), so it matches your broker's 損益試算 / 獲利率 rather than the gross gain
- **Cumulative earnings chart** stacking realized P/L + dividends
- **Unrealized P/L by position** with divergent green/red bars, sorted
- Open positions table + allocation donut

All live numbers update every 5 seconds while the Dashboard tab is visible — pauses on tab switch / minimize, resumes on return.

### 🔎 Per-stock detail (click any holding)
- **Yahoo-style key stats grid**: previous close, day's range, 52-week range, market cap, P/E, EPS, beta, dividend yield, ex-dividend date, **1-year analyst target** (with consensus count)
- **Your position card**: shares, avg cost, market value, realized + unrealized + dividends + total return (NT$ and %), yield on cost, holding period, fees paid
- **Historical price chart** (1M / 3M / 6M / 1Y / 2Y / 5Y / All) with your buys, sells, and dividends overlaid as markers; optional **TAIEX benchmark** overlay
- **Monthly revenue (月營收)** chart — TW-specific mandatory disclosure, 24 months in NT$ B with a YoY % line on a secondary axis
- **Quarterly earnings (季報)** — last 8 quarters of revenue, net income, diluted EPS, plus gross / operating / net margin
- **Activity timeline** of every trade and dividend on this ticker

### ✦ Agentic AI assistant
- **Drives the UI for you** — tell it "add a buy of 10 NVDA at 120" or "open the US portfolio and show me Apple," and it executes the steps on the real interface: a floating cursor glides to each control, a spotlight highlights it, forms get typed into and submitted. Add-only by design (it never edits or deletes existing records).
- Slide-in sidebar with persistent chat history (rename, delete, switch threads)
- **📎 Import trades from a screenshot or PDF** — drop a brokerage screenshot, Gemini extracts every trade and dividend (Taiwan-aware: 民國 dates → Gregorian, 張 → shares × 1000, 買進/賣出 → buy/sell). You review in an editable preview card with per-row checkboxes, then commit. Nothing writes to the DB until you confirm — and the dashboard auto-refreshes the moment you do.
- **📱 Send from your phone via QR** — opens a modal with a QR pointing to a session URL on your LAN. Scan with your phone's camera, take a photo of the statement, the desktop picks it up automatically and drops you into the same review-and-confirm preview. No AirDrop, no email, no cable.
- **Duplicate detection** — re-uploading a screenshot you already imported flags matching rows with an amber "Already imported" badge and unchecks them by default, so a careless click can't pollute your records.
- **Live Google Search grounding** — asks for "the latest news on 2330" and pulls fresh sources, with inline `[N]` citation chips that link directly to each domain (favicon + hostname)
- **Real-time SSE streaming** — text flows in word-by-word with a glowing pulse cursor, fading mask gradient on the tail edge so new tokens emerge from soft mist
- **"Searched the web · N sources · Xs"** thought-strip above each grounded reply; click to expand and see the actual queries Gemini ran
- Sees your **live portfolio + per-stock fundamentals on every holding**, and auto-detects ticker mentions to enrich context with monthly revenue + quarterly margins
- Markdown rendering: tables, bold, italics, lists, code blocks
- **Stop button** mid-generation; partial response is persisted with an "interrupted" tag
- **In-app modal** confirmations everywhere — chat delete, trade delete, dividend delete, CSV replace-all (no native browser dialogs)
- **Rotating capability tagline** on the welcome screen — cycles through what the AI can actually do (analyze, search, import, scan from phone), personalized to your biggest holding
- Personalized, reshuffleable suggestion cards covering portfolio, news, and market context — based on your top holdings

### 🛠 Trade & dividend management
- **One unified CSV** for trades and dividends with `kind` column
- Append OR replace import modes; "Last export" timestamp
- **Inline edit** on every row (click Edit, fields become inputs)
- Filter by ticker, type, status (open/closed), date range with presets
- **FIFO open/closed status** computed per trade
- Pagination 10 / 20 / 50 / 100 per page
- Auto-seed from `backend/data/seed/portfolio.csv` on first boot

---

## Demo

### Dashboard

![Dashboard](docs/screenshots/dashboard.png)

The headline number (realized + dividends), live market value, today's P/L, and a cumulative earnings chart that stacks realized + dividends.

### Stock detail — Yahoo-style key stats + your position

![Stock detail — key stats](docs/screenshots/stock-detail-top.png)

Click any open position to drill in. Key stats mirror Yahoo Finance, the position card adds your personalized P/L, return, and yield on cost.

### Stock detail — price history + monthly revenue (月營收)

![Stock detail — chart + monthly revenue](docs/screenshots/stock-detail-chart.png)

Historical prices with your buy / sell / dividend markers, plus the Taiwan-specific monthly revenue chart with year-over-year change overlaid.

### Stock detail — quarterly financials + activity timeline

![Stock detail — quarterly + activity](docs/screenshots/stock-detail-financials.png)

Last 8 quarters of revenue, net income, EPS, and margins. Activity timeline shows every trade + dividend on this ticker.

### Unrealized P/L by position

![Unrealized P/L](docs/screenshots/unrealized.png)

Divergent horizontal bars sorted by P/L, color-coded green/red. Re-paints every 5 s while the dashboard is visible.

### AI assistant — welcome screen

![AI Assistant — welcome](docs/screenshots/assistant-welcome.png)

Reshuffleable suggestion cards across **portfolio · news · market context**. Top picks are personalized to the tickers you actually own.

### AI assistant — grounded search with inline citations

![AI Assistant — grounded reply with citations](docs/screenshots/assistant-citations.png)

Asks Gemini → Gemini calls Google Search → response streams in word-by-word with `[N]` markers replaced by purple pill chips (favicon + domain) that link straight to the source. The header strip ("Searched the web · 6 sources · 6.7s") is clickable.

### AI assistant — see exactly what Gemini searched

![AI Assistant — search queries expanded](docs/screenshots/assistant-meta-expanded.png)

Tap the meta strip to expand the actual search queries the model ran, so you can audit where every claim came from.

### AI assistant — in-app delete confirmation

![AI Assistant — delete confirm modal](docs/screenshots/assistant-delete-modal.png)

No native browser alerts — destructive actions use a themed in-app modal that overlays the sidebar with backdrop blur, ESC-to-cancel, and Enter-to-confirm. The same component handles trade deletes, dividend deletes, and CSV replace-all confirmations.

### Agentic import — review parsed records before committing

![Import preview](docs/screenshots/import-preview.png)

Drop a brokerage screenshot or PDF on the 📎 button. Gemini extracts every trade and dividend into an editable preview card — each row has a checkbox, type pill, and inline-editable shares / price / date / fee. Re-uploading something you've already imported flags the matching rows with an amber **"Already imported"** badge and unchecks them by default.

### Send from your phone via QR

![QR upload modal](docs/screenshots/qr-upload-modal.png)

Click 📱, scan the QR with your phone's camera, take a photo, and the desktop picks it up automatically. The status badge cycles **Waiting for phone… → File received → AI is reading → Ready** and the modal closes itself, dropping you into the same review-and-confirm card.

### Mobile upload page

![Mobile upload](docs/screenshots/mobile-upload.png)

The phone-facing upload page is a self-contained, no-framework HTML page served by the backend at `/m/upload/{token}` — works over the LAN with no external assets. Tap to choose a photo or PDF (or take a fresh one), then upload — the laptop sees it within a second.

### Trades — filter, paginate, edit inline

![Trades](docs/screenshots/trades.png)

Filter bar combining ticker search, trade type, status, and date range. Stock names show under each ticker. Pagination at the bottom; inline edit on every row.

---

## Tech stack

```
Backend                                Frontend
─────────────────                      ─────────────────
FastAPI                                Vite
SQLAlchemy 2.0                         React 18 + TypeScript
  · SQLite (local default)             Recharts (charts)
  · Postgres / Neon (optional)         react-markdown (AI replies)
TWSE MIS    (live TW quotes)           remark-gfm (tables / GFM)
Yahoo       (live US quotes + history) Inter font
FinMind     (TW monthly revenue)       Pure CSS (no framework)
google-genai (Gemini AI)
quote relay + ngrok  (cloud TW quotes)
python-multipart · python-dotenv · psycopg
```

All market data flows through standardised public endpoints (TWSE MIS, Yahoo, FinMind) — no scraping, no broker login, no paid feeds. Because TWSE MIS only answers from Taiwan IPs, a hosted backend reaches it through a small **quote relay** running on a Taiwan/home connection, exposed at a permanent **ngrok** URL (see [Real-time TW quotes in the cloud](#real-time-tw-quotes-in-the-cloud-the-relay)). US quotes from Yahoo work from anywhere.

---

## Architecture

```mermaid
flowchart LR
  subgraph Browser
    UI[React + Vite UI<br/>polls every 5s]
  end
  subgraph Phone["Phone (same Wi-Fi)"]
    PhonePage[Mobile upload page<br/>scans QR, picks photo]
  end
  subgraph Backend["FastAPI :8011"]
    Trades["/api/trades · /api/dividends"]
    Portfolio["/api/portfolio/*<br/>holdings · overview · summary"]
    Markets["/api/markets<br/>DB-driven config"]
    Stock["/api/stock/:ticker/detail"]
    Data["/api/data/*"]
    AI["/api/ai/*<br/>chat · agentic planner"]
    Mobile["/api/mobile/sessions/*<br/>/m/upload/:token"]
    Quotes["tw_quotes · yahoo_quotes<br/>5s cache (TW + US)"]
    SInfo["stock_info.py — 1h fundamentals · 6h financials"]
    DB[("trades.db / Neon<br/>trades · markets · chats")]
  end
  TWSE[("TWSE MIS<br/>live TW · ~5s")]
  Relay["quote relay (TW IP)<br/>via ngrok — cloud hop"]
  YLive[("Yahoo<br/>live US quotes + FX")]
  YF[("yfinance<br/>history · fundamentals")]
  FM[("FinMind<br/>monthly revenue")]
  Gemini[("Google Gemini 2.5 Flash<br/>SSE streaming · vision · opt-in")]
  GSearch[("Google Search<br/>via Gemini grounding")]

  UI -- "fetch /api/*" --> Trades
  UI --> Portfolio
  UI --> Markets
  UI --> Stock
  UI --> Data
  UI -- "SSE stream" --> AI
  UI -- "create + poll" --> Mobile
  PhonePage -- "GET upload page" --> Mobile
  PhonePage -- "POST file" --> Mobile
  Trades --> DB
  Data --> DB
  Portfolio --> DB
  Markets --> DB
  Portfolio --> Quotes
  Stock --> Quotes
  Stock --> SInfo
  AI --> DB
  AI --> SInfo
  AI -- "chat + vision parse" --> Gemini
  Mobile -- "vision parse" --> Gemini
  Gemini -- "google_search tool" --> GSearch
  Quotes --> TWSE
  Quotes -. "cloud only" .-> Relay
  Relay --> TWSE
  Quotes --> YLive
  SInfo --> YF
  SInfo --> FM
```

---

## Project layout

```
backend/
  app/
    main.py            FastAPI app + CORS + seed-load + .env loader
    database.py        Trade, Dividend (+ market col), Metadata, Chat,
                       ChatMessage, Market, MarketHoliday models + seeding
    schemas.py         Pydantic request/response models
    routers/
      trades.py        CRUD + PUT + FIFO open/closed status per row
      dividends.py     CRUD + PUT for dividends
      portfolio.py     holdings / overview / summary / earnings / names / quote
      markets.py       market configs + holiday add/remove (DB-driven)
      data.py          unified portfolio.csv import + export
      ai.py            Gemini Q&A + agentic UI planner + chat history (CRUD)
      stock.py         per-stock detail (parallel live + fundamentals + financials)
    services/
      quotes.py        QuoteData + symbol resolution + TW/US market detection
      tw_quotes.py     TWSE MIS client (batched, 5s cache, name capture)
      yahoo_quotes.py  US live quotes via Yahoo (5s cache)
      quote_relay_client.py  cloud → relay hop for TW quotes (ngrok URL)
      markets.py       DB-driven market config: currency, hours, holidays, open/closed
      portfolio.py     avg-cost, realized P/L, daily earnings, gross MV
      stock_info.py    yfinance fundamentals + history + TAIEX,
                       FinMind monthly revenue, quarterly_income_stmt
      fx.py            USD↔TWD rate (Yahoo, cached) for combined net worth
      csv_io.py · xlsx_io.py   unified import / export
  quote_relay.py       run on a TW connection; cloud reaches MIS through it
  data/trades.db       (auto-created, gitignored)
frontend/
  src/
    App.tsx            shell + Overview / per-market Dashboard / Trades / Dividends
    api.ts             typed fetch client
    format.ts          money / percent / date + config-driven market hours
    index.css          premium dark theme + animated gradient mesh
    agent/             agentic executor — floating cursor + spotlight, drives DOM
    components/
      Overview.tsx            landing page: TW + US cards + combined net worth
      FlashValue.tsx          green/red flash wrapper for any live number
      PortfolioSummary.tsx    hero + per-currency cards (sticky last-good)
      PerformanceChart.tsx    stacked area earnings chart
      UnrealizedChart.tsx     divergent bar chart, sorted by P/L
      AllocationChart.tsx     donut + legend with names
      HoldingsTable.tsx       open positions, click → StockDetail modal
      StockDetail.tsx         per-stock modal (key stats + chart + financials)
      TradeForm.tsx           buy/sell entry with market + live name lookup
      TradeList.tsx           filter + paginate + inline edit + status
      DividendForm.tsx        dividend entry with live name lookup
      DividendList.tsx        filter + paginate + inline edit
      DataPanel.tsx           CSV import/export + last-export tracker
      MarketStatus.tsx        active market's open/closed pill (TW or US)
      Pagination.tsx          page-size + page-number controls
      AssistantPanel.tsx      Gemini chat sidebar (markdown, stop, history)
    hooks/
      useTickerName.ts        debounced ticker → name resolution
tools/
  start-relay-ngrok.ps1  one-click relay + permanent ngrok tunnel (TW quotes)
```

---

## Quick start

### Backend

```powershell
cd backend
pip install -r requirements.txt
python -m uvicorn app.main:app --reload --port 8011
```

API docs: <http://127.0.0.1:8011/docs>

> **Want to use the QR phone-upload feature?** Start uvicorn with
> `--host 0.0.0.0` instead, and allow inbound port 8011 through Windows
> Firewall — your phone needs to reach the backend over your Wi-Fi:
> ```powershell
> python -m uvicorn app.main:app --reload --port 8011 --host 0.0.0.0
> ```

### Frontend

```powershell
cd frontend
npm install
npm run dev
```

Open <http://127.0.0.1:5173>. Vite proxies `/api/*` to the backend on `:8011`.

### Cloud database (optional)

By default the app stores everything in a local SQLite file (`backend/data/trades.db`).
To use a cloud Postgres instead (e.g. a free [Neon](https://neon.tech) database — handy
for syncing across devices or deploying), set `DATABASE_URL` in `backend/.env`:

```
DATABASE_URL=postgresql://user:password@ep-xxx.us-west-2.aws.neon.tech/dbname?sslmode=require
```

The app auto-detects it (routing through `psycopg`) and falls back to SQLite when unset.

### AI assistant (optional)

Copy `backend/.env.example` → `backend/.env`, paste your free Gemini API key from <https://aistudio.google.com/apikey>:

```
GOOGLE_AI_API_KEY=AIza...
```

Restart the backend. The ✦ Assistant button now opens a chat panel instead of the setup hint.

### Deploy to the cloud (optional)

To reach the app from your phone or any device, host the three pieces — all have free tiers:

- **Database → [Neon](https://neon.tech)** (Postgres). Create a project, copy the connection string.
- **Backend → [Render](https://render.com)** (Web Service). The repo ships a [`render.yaml`](render.yaml)
  blueprint — point Render at the repo and set these env vars in the dashboard:
  `DATABASE_URL` (Neon), `GOOGLE_AI_API_KEY` (optional), `FRONTEND_ORIGINS` (your Vercel URL),
  and optionally `QUOTE_RELAY_URL` + `QUOTE_RELAY_SECRET` for live TW quotes (see below).
- **Frontend → [Vercel](https://vercel.com)** (static). Set **Root Directory** to `frontend` and add the
  env var `VITE_API_BASE` = your Render backend URL.

Deploy order: **backend first** (to get its URL) → frontend (with `VITE_API_BASE`) → then set
`FRONTEND_ORIGINS` on the backend to the frontend's URL so CORS allows it. Note both free tiers
"scale to zero," so the first request after idle takes ~30–60 s to wake, then it's fast. The QR
phone-upload feature assumes a local network and won't work over the public internet.

### Real-time TW quotes in the cloud (the relay)

TWSE MIS only answers requests from **Taiwan IPs**, so a cloud-hosted backend can't fetch live TW
prices directly — it falls back to Yahoo, which is **~15 min delayed** for TW. To get near-real-time
TW quotes on the deployed app, run the **quote relay** on a machine that *can* reach MIS and expose it
at a stable URL:

1. **Run** [`tools/start-relay-ngrok.ps1`](tools/start-relay-ngrok.ps1) (Windows). It starts
   `quote_relay.py` on `localhost:8500` and opens a **permanent [ngrok](https://ngrok.com) tunnel** to it.
2. **One-time ngrok setup** — a free ngrok account gives you one free static domain; paste your
   authtoken + domain into `tools/ngrok_authtoken.txt` / `tools/ngrok_domain.txt` (the script reads them).
3. **Point the backend at it** — set `QUOTE_RELAY_URL` (your ngrok URL) and `QUOTE_RELAY_SECRET`
   (matching `tools/relay_secret.txt`) in Render's env. The cloud now borrows your machine's TW
   connection just for the quote hop; everything else stays on the cloud.

The relay is read-only (quotes only — it never touches your DB). TW prices are live while the relay is
running; when it's off, the app transparently falls back to delayed Yahoo. **US prices need no relay** —
Yahoo serves them from anywhere. Tell the source apart on `/api/portfolio/quote/2330`: the MIS feed
returns the Chinese name (台積電) and bid/ask/volume; Yahoo returns the English name only.

---

## How it works

- **Market detection** — a ticker's format decides its market: numeric codes (`2330`, `00919`, `00937B`) → **TW / TWD**, alphabetic symbols (`NVDA`, `BRK.B`) → **US / USD**. Each trade/dividend also carries an explicit `market` column.
- **Ticker resolution** — bare 4-6 digit TW codes auto-suffix to `xxxx.TW`; US symbols resolve directly.
- **Live quotes** — TW tickers go to **TWSE MIS** (batched into one HTTP call per refresh, probing both `tse_` 上市 and `otc_` 上櫃 prefixes); US tickers go to **Yahoo**. Both are cached ~5 s server-side so the 5 s frontend poll tracks the broker closely without hammering either source.
- **Combined net worth** — the Overview sums both portfolios into one figure shown in NT$ **and** US$, converting with a live USD↔TWD rate (Yahoo, cached). If a market that holds positions is missing a live value, the combined total blanks rather than showing a fabricated number.
- **Cost basis** — weighted-average. Sells reduce open cost basis proportionally and realize the difference vs. average price (minus fees).
- **Market value** — `current_price × shares`, gross. Matches 資產市值 / 總現值 in most TW broker apps.
- **Unrealized P/L** — market value − cost basis − estimated exit cost (sell commission 0.1425% + securities transaction tax: 0.3% shares / 0.1% equity ETFs / 0% bond ETFs, each floored). This nets out the cost of liquidating, so it lines up with the broker's 損益試算 / 獲利率 columns rather than the gross gain.
- **Open vs closed status** — FIFO-matched per ticker: buys queue up; sells consume buy lots front-first; any buy lot with leftover shares is `open`, fully-consumed buys and all sells are `closed`.
- **Per-stock detail** — `/api/stock/{ticker}/detail` aggregates the live quote + yfinance fundamentals (1 h cache) + daily history + FinMind monthly revenue (TW) + yfinance quarterly financials (6 h cache) + your local trades / dividends in one call. The five upstream fetches run **concurrently**, so the modal loads in ~the slowest single call instead of the sum.
- **AI context** — every chat sends your full portfolio JSON + light fundamentals on every holding. If your question mentions a ticker, deep monthly revenue + quarterly margins for that ticker also get attached so the model can answer trend questions with citations.

### Live data flow

The Dashboard tab polls `/api/portfolio/{holdings,summary,earnings-history,names}` every 5 s while it's the active view AND the browser tab is visible (the Overview polls its own summary every 15 s). The server-side quote caches (~5 s) absorb duplicate calls, and `names` is cached ~10 min so the poll never re-fetches quotes for closed positions. Live numbers **flash green/red** as they tick.

The header shows two pills, **scoped to the market you're viewing**:

- **● TW OPEN / US OPEN** (green, pulsing) during that market's hours — TW 09:00–13:30 Taipei, US 09:30–16:00 New York — **● CLOSED** (grey) otherwise. Hours, holidays, and timezone come from the DB `markets` config, so it's correct per market and editable without a redeploy.
- **● LIVE** (green, pulsing) appears whenever the polling loop is active. Disappears the moment you switch tabs, minimize, or navigate away.

Outside market hours MIS rolls `y` (yesterday's close) over to today's close, but the parser caches the last good quote per ticker and uses bid/ask midpoint / `o` (today's open) as fallbacks — so the TODAY column doesn't collapse to 0 % between trades.

---

## CSV import / export

The app uses **one unified CSV** for both trades and dividends. The **Data** tab has Export and Import buttons.

Each row's `kind` column tells the backend whether it's a trade or a dividend:

```
kind,type,ticker,shares,price,date,fee,amount,notes
trade,buy,2330,100,950,2024-01-15,28,,initial buy
trade,sell,2330,100,1100,2024-06-01,30,,closed
dividend,,2330,,,2024-08-15,,5,Q2 cash dividend
```

- For `kind=trade`: fill `type` (buy/sell), `shares`, `price`, `date`, `fee`, `notes` (optional). Leave `amount` blank.
- For `kind=dividend`: fill `ticker`, `date`, `amount`, `notes` (optional). Leave the trade-only columns blank.
- Dates accept `YYYY-MM-DD`, `YYYY/MM/DD`, or `MM/DD/YYYY`.
- Two import modes: **append** (default, adds rows) and **replace** (wipes existing trades + dividends, then imports). The `kind=replace` mode is used for round-trip identity testing.

### Auto-seed on first boot

Drop a file at `backend/data/seed/portfolio.csv` and the backend loads it on startup — **but only when both tables are empty.** First boot with no DB → the seed file is imported automatically. Once you have any data → the seed file is ignored. To re-seed: delete `backend/data/trades.db`, then restart.

---

## Endpoints

| Method | Path                                | Purpose                                     |
|--------|-------------------------------------|---------------------------------------------|
| GET    | /api/health                         | liveness                                    |
| GET    | /api/trades                         | list trades, newest first                   |
| POST   | /api/trades                         | create a trade                              |
| PUT    | /api/trades/{id}                    | update a trade                              |
| DELETE | /api/trades/{id}                    | delete a trade                              |
| GET    | /api/dividends                      | list dividends, newest first                |
| POST   | /api/dividends                      | create a dividend                           |
| PUT    | /api/dividends/{id}                 | update a dividend                           |
| DELETE | /api/dividends/{id}                 | delete a dividend                           |
| GET    | /api/data/export                    | download unified portfolio CSV              |
| POST   | /api/data/import?mode={append,replace} | upload unified CSV                       |
| GET    | /api/data/last-export               | timestamp of most recent export             |
| GET    | /api/portfolio/holdings             | per-ticker open positions + live P/L (TW + US) |
| GET    | /api/portfolio/overview             | TW + US summary cards + combined net worth (NT$ & US$) + FX |
| GET    | /api/portfolio/summary              | per-currency totals incl. dividends + total earned |
| GET    | /api/portfolio/names                | ticker → short-name map (e.g. 2330→台積電)    |
| GET    | /api/portfolio/realized-history?days=N | daily cumulative realized P/L            |
| GET    | /api/portfolio/earnings-history?days=N | daily cumulative realized + dividends    |
| GET    | /api/portfolio/quote/{ticker}       | live spot quote (price + name)              |
| GET    | /api/stock/{ticker}/detail?period=  | live + fundamentals + history + financials (parallel-fetched) |
| GET    | /api/markets                        | market configs (TW/US): currency, timezone, hours, holidays |
| POST   | /api/markets/{code}/holidays        | add a market closure (date, name?) — no redeploy |
| DELETE | /api/markets/{code}/holidays/{date} | remove a market closure                     |
| GET    | /api/ai/status                      | whether GOOGLE_AI_API_KEY is configured     |
| POST   | /api/ai/chat                        | SSE stream: `init` → `chunk` × N → `done` (or `error`); persists final reply with `[N]` citation markers |
| POST   | /api/ai/parse-records               | upload an image/PDF, get `{trades, dividends, notes}` back — read-only, nothing written to DB |
| GET    | /api/ai/chats                       | list saved conversations, newest first      |
| GET    | /api/ai/chats/{id}                  | fetch one conversation with all messages    |
| PATCH  | /api/ai/chats/{id}                  | rename a conversation                       |
| DELETE | /api/ai/chats/{id}                  | delete a conversation (cascades messages)   |
| POST   | /api/mobile/sessions                | mint a QR upload session, returns `{token, url, expires_in, lan_ip}` |
| GET    | /api/mobile/sessions/{token}        | desktop polls this; status transitions `pending → received → parsing → ready` |
| DELETE | /api/mobile/sessions/{token}        | release session bytes when modal closes     |
| POST   | /api/mobile/sessions/{token}/file   | phone uploads here from the mobile page     |
| GET    | /m/upload/{token}                   | mobile-friendly upload HTML page (rendered by phone after QR scan) |

---

## AI assistant

The **✦ Assistant** button in the header opens a slide-in sidebar with natural-language Q&A over your portfolio, powered by Google Gemini. Gated by an API key — without one the sidebar shows setup instructions and the rest of the app works normally.

### What it knows

- Every open position with **light fundamentals** (sector, P/E, EPS, market cap, 52-week range, dividend yield, beta, 1-year analyst target, earnings / ex-div dates).
- Every trade and dividend you've recorded.
- For tickers you mention in the question (or in recent turns): **24 months of monthly revenue with YoY %** and **8 quarters of revenue / EPS / margins**.
- **Anything live on the web** via Gemini's built-in Google Search tool — recent news, regulatory filings, analyst commentary, macro events, conference call summaries.

This means questions like *"is 2330's gross margin improving?"* or *"compare 2330's price to its 1-year analyst target"* return tables with real numbers from your data — not generic boilerplate. Ask *"what's the latest news on 2330?"* and Gemini searches the web, writes a summary, and **inline citation chips** link each claim back to its source.

### Streaming + citations

- Backend uses `client.models.generate_content_stream` and emits Server-Sent Events: `init` → `chunk` (per token) → `done` (canonical content with `[N]` markers + Sources block).
- Frontend consumes the SSE via `fetch` + `ReadableStream`, appends deltas to a placeholder message in real time, and swaps in the canonical version when the stream ends — so citations always settle on stable byte offsets from `grounding_supports`.
- A trailing pulse-logo cursor follows the streamed text; a soft fade-mask gradient on the bottom edge of the response makes new tokens emerge from soft transparency rather than popping in.
- The "Searched the web · N sources · X.Xs" header is parsed from a hidden `<!--meta:...-->` JSON prefix the backend embeds at persist time; expandable to reveal the exact `web_search_queries` Gemini issued.

### Persistent chat history

- The first user message becomes the chat title (auto-truncated, can be renamed).
- Click **☰** in the sidebar header to see all saved chats with title, message count, and relative time. Click a row to switch into it.
- Hover any row for ✏ rename and 🗑 delete.
- Click **+** to start a fresh chat without losing your history.
- The most recently viewed chat is restored automatically when you reopen the sidebar.

### What it can / can't do

- ✅ Answer questions from your local data + per-ticker fundamentals + live web search results.
- ✅ Cite every web-sourced claim with a clickable inline pill chip and a domain label.
- ✅ Stream responses token-by-token over SSE; **Stop** to interrupt (partial reply is saved).
- ❌ Won't give buy/sell recommendations or price predictions, even when relaying analyst opinions found via search — those are framed as observations, never advice.

### Privacy tradeoff

When you ask a question, your portfolio JSON + ticker fundamentals are sent to Google's API for inference, and Gemini may issue Google Search queries on your behalf. TWSE MIS quotes still happen locally. If you don't want any data going to Google, leave `GOOGLE_AI_API_KEY` unset and the assistant stays disabled — the rest of the app continues working.

> **Free tier note:** Google may use your prompts to improve their models on the free Gemini API tier. Switch to billing-enabled Vertex AI / Cloud if that's a dealbreaker.

---

## Privacy

- Your trade data lives in `backend/data/trades.db` (SQLite, on disk).
- The DB and any `seed/` files are gitignored — never pushed to GitHub.
- Outbound calls:
  - **TWSE MIS** (`https://mis.twse.com.tw`) — live TW quotes (directly when local; via your own quote relay when cloud-hosted).
  - **Yahoo Finance** — live US quotes, daily history + fundamentals, and the USD↔TWD rate (no auth, public).
  - **FinMind** (`https://api.finmindtrade.com`) — TW monthly revenue (no auth on the free tier).
  - **ngrok** — only if you run the optional TW quote relay; it tunnels *your* relay (quotes only, never your DB).
  - **Google AI** (`https://generativelanguage.googleapis.com`) — only when you've set `GOOGLE_AI_API_KEY` and ask a question in the Assistant.
  - **Google Search** — invoked indirectly by Gemini's `google_search` tool when grounding a reply. URLs returned are Vertex AI redirect URLs that proxy to the actual source on click.
- No analytics, no telemetry, no third-party storage.
