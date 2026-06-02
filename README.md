<div align="center">

# ✦ AI Stock Studio

A self-hosted **Taiwan equities workbench** — live MIS prices, broker-matching P/L, per-stock fundamentals, monthly revenue, quarterly financials, and a streaming AI assistant that **searches the web for fresh news, cites every claim, and analyzes your portfolio** alongside it.

</div>

![Dashboard](docs/screenshots/dashboard.png)

> Built because every off-the-shelf TW portfolio tracker either ignores
> dividends, charges money, or sends your trade history to a third party.
> This one runs on your laptop, stores everything in a local SQLite file,
> and only talks to TWSE MIS for live quotes — no other outbound calls
> (the AI assistant is opt-in and gated by your own key).

---

## What's inside

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
Backend                            Frontend
─────────────────                  ─────────────────
FastAPI                            Vite
SQLAlchemy 2.0                     React 18 + TypeScript
  · SQLite (local default)         Recharts (charts)
  · Postgres / Neon (optional)     react-markdown (AI replies)
TWSE MIS  (live quotes)            remark-gfm (tables / GFM)
yfinance  (history + fundamentals) Inter font
FinMind   (TW monthly revenue)     Pure CSS (no framework)
google-genai (Gemini AI)
python-multipart · python-dotenv · psycopg
```

All TW data flows through standardised endpoints (TWSE MIS, FinMind, yfinance) — no scraping, no broker login, no paid feeds.

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
  subgraph Backend["FastAPI :8001"]
    Trades["/api/trades"]
    Dividends["/api/dividends"]
    Portfolio["/api/portfolio/*"]
    Stock["/api/stock/:ticker/detail"]
    Data["/api/data/*"]
    AI["/api/ai/*"]
    Mobile["/api/mobile/sessions/*<br/>/m/upload/:token"]
    Quotes["tw_quotes.py — 5s in-mem cache"]
    SInfo["stock_info.py — 1h fundamentals · 6h financials"]
    DB[("SQLite trades.db<br/>chats · chat_messages")]
  end
  TWSE[("TWSE MIS<br/>~5s")]
  YF[("yfinance<br/>history · fundamentals")]
  FM[("FinMind<br/>monthly revenue")]
  Gemini[("Google Gemini 2.5 Flash<br/>SSE streaming · vision · opt-in")]
  GSearch[("Google Search<br/>via Gemini grounding")]

  UI -- "fetch /api/*" --> Trades
  UI --> Dividends
  UI --> Portfolio
  UI --> Stock
  UI --> Data
  UI -- "SSE stream" --> AI
  UI -- "create + poll" --> Mobile
  PhonePage -- "GET upload page" --> Mobile
  PhonePage -- "POST file" --> Mobile
  Trades --> DB
  Dividends --> DB
  Data --> DB
  Portfolio --> DB
  Portfolio --> Quotes
  Stock --> Quotes
  Stock --> SInfo
  AI --> DB
  AI --> SInfo
  AI -- "chat + vision parse" --> Gemini
  Mobile -- "vision parse" --> Gemini
  Gemini -- "google_search tool" --> GSearch
  Quotes --> TWSE
  SInfo --> YF
  SInfo --> FM
```

---

## Project layout

```
backend/
  app/
    main.py            FastAPI app + CORS + seed-load + .env loader
    database.py        Trade, Dividend, Metadata, Chat, ChatMessage models
    schemas.py         Pydantic request/response models
    routers/
      trades.py        CRUD + PUT + FIFO open/closed status per row
      dividends.py     CRUD + PUT for dividends
      portfolio.py     holdings / summary / earnings-history / names / quote
      data.py          unified portfolio.csv import + export
      ai.py            Gemini Q&A + persistent chat history (CRUD)
      stock.py         per-stock detail (live + fundamentals + financials)
    services/
      quotes.py        QuoteData + symbol resolution
      tw_quotes.py     TWSE MIS client (batched, 5s cache, name capture)
      portfolio.py     avg-cost, realized P/L, daily earnings, gross MV
      stock_info.py    yfinance fundamentals + history + TAIEX,
                       FinMind monthly revenue, quarterly_income_stmt
      csv_io.py        unified CSV parse + serialize
  data/trades.db       (auto-created, gitignored)
frontend/
  src/
    App.tsx            shell + Dashboard / Trades / Dividends / Data tabs
    api.ts             typed fetch client
    format.ts          money / percent / date / TW-detection helpers
    index.css          premium dark theme + animated gradient mesh
    components/
      PortfolioSummary.tsx    hero + per-currency cards (sticky last-good)
      PerformanceChart.tsx    stacked area earnings chart
      UnrealizedChart.tsx     divergent bar chart, sorted by P/L
      AllocationChart.tsx     donut + legend with names
      HoldingsTable.tsx       open positions, click → StockDetail modal
      StockDetail.tsx         per-stock modal (key stats + chart + financials)
      TradeForm.tsx           buy/sell entry with live name lookup
      TradeList.tsx           filter + paginate + inline edit + status
      DividendForm.tsx        dividend entry with live name lookup
      DividendList.tsx        filter + paginate + inline edit
      DataPanel.tsx           CSV import/export + last-export tracker
      MarketStatus.tsx        TW market open/closed pill
      Pagination.tsx          page-size + page-number controls
      AssistantPanel.tsx      Gemini chat sidebar (markdown, stop, history)
    hooks/
      useTickerName.ts        debounced ticker → name resolution
```

---

## Quick start

### Backend

```powershell
cd backend
pip install -r requirements.txt
python -m uvicorn app.main:app --reload --port 8001
```

API docs: <http://127.0.0.1:8001/docs>

> **Want to use the QR phone-upload feature?** Start uvicorn with
> `--host 0.0.0.0` instead, and allow inbound port 8001 through Windows
> Firewall — your phone needs to reach the backend over your Wi-Fi:
> ```powershell
> python -m uvicorn app.main:app --reload --port 8001 --host 0.0.0.0
> ```

### Frontend

```powershell
cd frontend
npm install
npm run dev
```

Open <http://127.0.0.1:5173>. Vite proxies `/api/*` to the backend on `:8001`.

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
  `DATABASE_URL` (Neon), `GOOGLE_AI_API_KEY` (optional), and `FRONTEND_ORIGINS` (your Vercel URL).
- **Frontend → [Vercel](https://vercel.com)** (static). Set **Root Directory** to `frontend` and add the
  env var `VITE_API_BASE` = your Render backend URL.

Deploy order: **backend first** (to get its URL) → frontend (with `VITE_API_BASE`) → then set
`FRONTEND_ORIGINS` on the backend to the frontend's URL so CORS allows it. Note both free tiers
"scale to zero," so the first request after idle takes ~30–60 s to wake, then it's fast. The QR
phone-upload feature assumes a local network and won't work over the public internet.

---

## How it works

- **Ticker resolution** — bare 4-6 digit codes (`2330`, `00919`, `00937B`) auto-suffix to `xxxx.TW` against TWSE MIS.
- **Live quotes** — TW tickers go to TWSE MIS, batched into a single HTTP call per refresh. We probe both `tse_` (上市) and `otc_` (上櫃) prefixes per ticker so callers don't need to know which exchange.
- **Cost basis** — weighted-average. Sells reduce open cost basis proportionally and realize the difference vs. average price (minus fees).
- **Market value** — `current_price × shares`, gross. Matches 資產市值 / 總現值 in most TW broker apps.
- **Unrealized P/L** — market value − cost basis − estimated exit cost (sell commission 0.1425% + securities transaction tax: 0.3% shares / 0.1% equity ETFs / 0% bond ETFs, each floored). This nets out the cost of liquidating, so it lines up with the broker's 損益試算 / 獲利率 columns rather than the gross gain.
- **Open vs closed status** — FIFO-matched per ticker: buys queue up; sells consume buy lots front-first; any buy lot with leftover shares is `open`, fully-consumed buys and all sells are `closed`.
- **Per-stock detail** — `/api/stock/{ticker}/detail` aggregates live MIS quote + yfinance fundamentals (1 h cache) + yfinance daily history + FinMind monthly revenue + yfinance quarterly_income_stmt (6 h cache) + your local trades / dividends — all in one call.
- **AI context** — every chat sends your full portfolio JSON + light fundamentals on every holding. If your question mentions a ticker, deep monthly revenue + quarterly margins for that ticker also get attached so the model can answer trend questions with citations.

### Live data flow

The Dashboard tab polls `/api/portfolio/{holdings,summary,earnings-history,names}` every 5 s while it's the active view AND the browser tab is visible. The backend's MIS cache (5 s TTL) absorbs duplicate calls, so even with multiple browser tabs open you'll hit MIS once per 5 s per ticker batch.

The header shows two pills:

- **● TW OPEN** (green, pulsing) when 09:00 ≤ Taipei time < 13:30 on weekdays. **● TW CLOSED** (grey) otherwise. Auto-flips at 09:00 / 13:30; checks every 60 s.
- **● LIVE** (green, pulsing) appears whenever the polling loop is active. Disappears the moment you switch tabs, minimize, or navigate away from the Dashboard.

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
| GET    | /api/portfolio/holdings             | per-ticker open positions + live P/L        |
| GET    | /api/portfolio/summary              | TWD totals incl. dividends + total earned   |
| GET    | /api/portfolio/names                | ticker → short-name map (e.g. 2330→台積電)    |
| GET    | /api/portfolio/realized-history?days=N | daily cumulative realized P/L            |
| GET    | /api/portfolio/earnings-history?days=N | daily cumulative realized + dividends    |
| GET    | /api/portfolio/quote/{ticker}       | live spot quote (price + name)              |
| GET    | /api/stock/{ticker}/detail?period=  | live + fundamentals + history + financials  |
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
  - **TWSE MIS** (`https://mis.twse.com.tw`) — live quotes, always.
  - **yfinance / Yahoo Finance** — daily history + fundamentals (no auth, public).
  - **FinMind** (`https://api.finmindtrade.com`) — TW monthly revenue (no auth on the free tier).
  - **Google AI** (`https://generativelanguage.googleapis.com`) — only when you've set `GOOGLE_AI_API_KEY` and ask a question in the Assistant.
  - **Google Search** — invoked indirectly by Gemini's `google_search` tool when grounding a reply. URLs returned are Vertex AI redirect URLs that proxy to the actual source on click.
- No analytics, no telemetry, no third-party storage.
