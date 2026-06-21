<div align="center">

# ✦ AI Stock Studio

A **native iOS app + FastAPI backend** for tracking **Taiwan + US** stock portfolios — live prices, broker-matching P/L, per-stock fundamentals, a **combined net-worth overview** across both markets (NT$ and US$), and a streaming AI assistant (your choice of **OpenAI, Gemini, or Claude**) that analyzes your portfolio and can search the web.

</div>

<div align="center">
<img src="docs/screenshots/ios-overview.png" width="250" alt="Net-worth overview" />
&nbsp;&nbsp;
<img src="docs/screenshots/ios-dashboard.png" width="250" alt="Portfolio dashboard" />
&nbsp;&nbsp;
<img src="docs/screenshots/ios-assistant.png" width="250" alt="AI assistant" />
</div>

> Built because every off-the-shelf portfolio tracker either ignores
> dividends, charges money, or sends your trade history to a third party.
> The backend runs anywhere (your machine, or a free Render + Neon deploy),
> stores everything in SQLite or your own Neon Postgres, and only pulls public
> market data — TWSE MIS for Taiwan, Yahoo for US — with no broker login. The AI
> assistant is opt-in and gated by your own provider key.

---

## 📱 Native iOS app

A native **SwiftUI** iPhone app (in [`ios/`](ios/)) talks to the same FastAPI backend — bottom tab bar, dark "studio" theme, Swift Charts, an animated splash, Google sign-in, multi-provider AI (OpenAI / Gemini / Claude with your own key), **Claude-style Markdown** in the assistant, and per-user data scoping. Build the sideloadable `.ipa` with [`ios/rebuild-ipa.sh`](ios/rebuild-ipa.sh) and install it permanently via SideStore — see the [install guide](ios/INSTALL_ON_IPHONE.md). (Screenshots at the top of this README.)

## 🌐 Web dashboard (mobile + desktop)

A responsive **read-only** web dashboard (in [`frontend/`](frontend/), React + Vite) lets you check the portfolio from any phone or computer over the internet — net worth, a total-earned chart, per-market cards, and live holdings. Access is gated by a single shared password (`WEB_DASHBOARD_PASSWORD`); it reads the scope set by `WEB_DASHBOARD_USER_ID` (default `legacy`). Deploy it to Vercel pointing at your Render backend — see [`frontend/README.md`](frontend/README.md).

---

## What's inside

### 🌏 Multi-market overview (TW + US)
- **Two portfolios, one app** — Taiwan (TWD) and US (USD) holdings are tracked separately, each with their own dashboard, trades, and dividends. Market is detected from the ticker format (numeric → TW, letters → US).
- **Overview landing page** — a TW card and a US card showing each market's value, total P/L, and today's move. Tap a card to enter that portfolio; the back button returns you to the overview.
- **Combined net worth** — both portfolios summed into a single figure shown in **both NT$ and US$**, with the live USD↔TWD rate. The number flashes green/red as it ticks.
- **Color-coded P&L** — gains render green, losses red, across the net worth, market cards, summary, and every holding.
- **DB-driven market config** — trading hours, holidays, currency, and timezone for each market live in the database (`markets` + `market_holidays` tables), not hardcoded, so the open/closed status is correct per market and editable without a redeploy.

### 📊 Live portfolio dashboard
- Hero **Total Earned** card (realized + dividends) with gradient styling
- **Total Return** card — realized + dividends + unrealized, your all-in profit
- Per-currency summary grid: market value, unrealized P/L, realized P/L, dividends, and today's move (accent-colored)
- Unrealized P/L is **net of estimated exit costs** (sell commission + transaction tax), so it matches your broker's 損益試算 / 獲利率 rather than the gross gain
- **Cumulative earnings chart** (Swift Charts) stacking realized P/L + dividends
- **Holdings list** — each position with shares, avg cost, market value, and unrealized P&L

Holdings/summary refresh while a portfolio is on screen — every 5 s while that market is open, 60 s otherwise.

### 🔎 Per-stock detail (tap any holding)
- **Live quote header** + key stats: previous close, day range, market cap, P/E, EPS, beta, dividend yield, 52-week range, **1-year analyst target**
- **Your position card**: shares, avg cost, market value, realized + unrealized + dividends + total return (and %)
- **Price-history chart** (1M / 3M / 6M / 1Y / 2Y / 5Y / All) with your buys, sells, and dividends overlaid as markers
- The backend `/detail` endpoint also serves **monthly revenue (月營收)** and **8 quarters of financials** for any ticker — used to enrich AI answers

### ✦ AI assistant
- **Choose your model** — OpenAI, Google Gemini, or Anthropic Claude, each with **your own API key** (entered in-app, stored in the iOS Keychain, sent per-request — never stored on the server).
- **Streaming replies** rendered as **Claude-style Markdown** — headings, bold, lists, code blocks, blockquotes — with an animated typing indicator.
- **Portfolio-aware** — every chat sends your live holdings + light fundamentals; mention a ticker and its monthly revenue + quarterly margins are attached so the model answers with real numbers.
- **Web-search grounding (Gemini)** — ask for the latest news and Gemini searches the web, with inline `[N]` citations linking to each source.
- **Chat history** — past conversations are saved; reopen one, delete with a swipe, or clear them all.

### 🛠 Trade & dividend management
- Add, edit, and delete **trades** (buy/sell) and **dividends**, scoped per market (TW / US)
- **FIFO open/closed status** computed per trade; weighted-average cost basis
- Backend **CSV import/export** endpoints (one unified file for trades + dividends) and auto-seed from `backend/data/seed/portfolio.csv` on first boot

### 🔐 Accounts & data
- **Google sign-in** (login only) via the native OAuth flow — or continue as a guest
- **Per-user data scoping** — each signed-in account sees only its own trades, dividends, and chats; un-authenticated requests fall back to a shared "legacy" bucket

---

## Tech stack

```
Backend                                iOS app (native)
─────────────────                      ─────────────────
FastAPI                                Swift + SwiftUI
SQLAlchemy 2.0                         Swift Charts
  · SQLite (local default)             URLSession (async/await)
  · Postgres / Neon (optional)         Keychain (API keys)
TWSE MIS   (live TW quotes)            ASWebAuthenticationSession (Google)
Yahoo      (live US quotes + history)
FinMind    (TW monthly revenue)        Multi-provider AI (your own key):
google-genai · openai · anthropic        OpenAI / Gemini / Claude
quote relay + ngrok (cloud TW quotes)
python-multipart · python-dotenv · psycopg · google-auth
```

All market data flows through standardised public endpoints (TWSE MIS, Yahoo, FinMind) — no scraping, no broker login, no paid feeds. Because TWSE MIS only answers from Taiwan IPs, a hosted backend reaches it through a small **quote relay** running on a Taiwan/home connection, exposed at a permanent **ngrok** URL (see [Real-time TW quotes in the cloud](#real-time-tw-quotes-in-the-cloud-the-relay)). US quotes from Yahoo work from anywhere.

---

## Architecture

```mermaid
flowchart LR
  subgraph iPhone["iPhone — native SwiftUI app"]
    UI[Overview · Dashboard · Trades<br/>Dividends · Stock detail · Assistant]
  end
  subgraph Backend["FastAPI"]
    Trades["/api/trades · /api/dividends"]
    Portfolio["/api/portfolio/*<br/>holdings · overview · summary"]
    Markets["/api/markets<br/>DB-driven config"]
    Stock["/api/stock/:ticker/detail"]
    Data["/api/data/*"]
    AI["/api/ai/*<br/>chat (OpenAI/Gemini/Claude)"]
    Auth["auth — verify Google ID token<br/>per-user scoping"]
    Quotes["tw_quotes · yahoo_quotes<br/>5s cache (TW + US)"]
    SInfo["stock_info.py — 1h fundamentals · 6h financials"]
    DB[("trades.db / Neon<br/>trades · markets · chats (per user)")]
  end
  Google[("Google Sign-In<br/>OAuth — login only")]
  TWSE[("TWSE MIS<br/>live TW · ~5s")]
  Relay["quote relay (TW IP)<br/>via ngrok — cloud hop"]
  YLive[("Yahoo<br/>live US quotes + FX")]
  YF[("yfinance<br/>history · fundamentals")]
  FM[("FinMind<br/>monthly revenue")]
  LLM[("OpenAI · Gemini · Anthropic<br/>user's own key · SSE streaming")]
  GSearch[("Google Search<br/>via Gemini grounding")]

  UI -- "fetch /api/* (Bearer token)" --> Trades
  UI --> Portfolio
  UI --> Markets
  UI --> Stock
  UI --> Data
  UI -- "SSE stream" --> AI
  UI -- "sign in" --> Google
  Trades --> Auth
  AI --> Auth
  Trades --> DB
  Data --> DB
  Portfolio --> DB
  Markets --> DB
  Portfolio --> Quotes
  Stock --> Quotes
  Stock --> SInfo
  AI --> DB
  AI --> SInfo
  AI -- "chat (user key)" --> LLM
  LLM -- "google_search (Gemini)" --> GSearch
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
ios/                   native SwiftUI iPhone app (see ios/README.md)
  StockTracker/
    App/ Config/ Networking/ Models/ Stores/ Theme/ Util/
    Auth/              Keychain + Google sign-in (ASWebAuthSession + PKCE)
    Views/             Overview, Dashboard, Trades, Dividends, StockDetail,
                       Assistant (Markdown chat + history), Settings, Onboarding
  rebuild-ipa.sh       build the sideloadable .ipa
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

> To reach the backend from a physical iPhone on your Wi-Fi, start uvicorn with
> `--host 0.0.0.0` and set the app's backend URL (Settings) to your Mac's LAN IP.

### iOS app

Open the SwiftUI project in Xcode and Run, or build a sideloadable `.ipa`:

```bash
cd ios
xcodegen generate && open StockTracker.xcodeproj   # run from Xcode, or:
./rebuild-ipa.sh                                    # -> ios/dist/StockTracker.ipa
```

The app defaults to the deployed backend (change it in the in-app Settings). See
[`ios/README.md`](ios/README.md) and [`ios/INSTALL_ON_IPHONE.md`](ios/INSTALL_ON_IPHONE.md).

### Cloud database (optional)

By default the app stores everything in a local SQLite file (`backend/data/trades.db`).
To use a cloud Postgres instead (e.g. a free [Neon](https://neon.tech) database — handy
for syncing across devices or deploying), set `DATABASE_URL` in `backend/.env`:

```
DATABASE_URL=postgresql://user:password@ep-xxx.us-west-2.aws.neon.tech/dbname?sslmode=require
```

The app auto-detects it (routing through `psycopg`) and falls back to SQLite when unset.

### AI assistant (optional)

In the app's **Settings → AI Assistant**, pick a provider (OpenAI / Gemini / Claude) and paste **your own API key** — it's stored in the iOS Keychain and sent per request.

Optionally set a server-side Gemini key so the app can use Gemini with no per-user key: copy `backend/.env.example` → `backend/.env`, add `GOOGLE_AI_API_KEY=AIza...` (free key at <https://aistudio.google.com/apikey>), and restart the backend.

### Deploy to the cloud (optional)

To reach the app from your phone or any device, host the two pieces — both have free tiers:

- **Database → [Neon](https://neon.tech)** (Postgres). Create a project, copy the connection string.
- **Backend → [Render](https://render.com)** (Web Service). The repo ships a [`render.yaml`](render.yaml)
  blueprint — point Render at the repo and set these env vars in the dashboard:
  `DATABASE_URL` (Neon), `GOOGLE_AI_API_KEY` (optional), `GOOGLE_CLIENT_ID` (for app sign-in),
  and optionally `QUOTE_RELAY_URL` + `QUOTE_RELAY_SECRET` for live TW quotes (see below).

The iOS app points at the Render backend URL (set in the app's Settings). The free tier
"scales to zero," so the first request after idle takes ~30–60 s to wake, then it's fast.

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
- **Live quotes** — TW tickers go to **TWSE MIS** (batched into one HTTP call per refresh, probing both `tse_` 上市 and `otc_` 上櫃 prefixes); US tickers go to **Yahoo**. Both are cached ~5 s server-side so the 5 s client poll tracks the broker closely without hammering either source.
- **Combined net worth** — the Overview sums both portfolios into one figure shown in NT$ **and** US$, converting with a live USD↔TWD rate (Yahoo, cached). If a market that holds positions is missing a live value, the combined total blanks rather than showing a fabricated number.
- **Cost basis** — weighted-average. Sells reduce open cost basis proportionally and realize the difference vs. average price (minus fees).
- **Market value** — `current_price × shares`, gross. Matches 資產市值 / 總現值 in most TW broker apps.
- **Unrealized P/L** — market value − cost basis − estimated exit cost (sell commission 0.1425% + securities transaction tax: 0.3% shares / 0.1% equity ETFs / 0% bond ETFs, each floored). This nets out the cost of liquidating, so it lines up with the broker's 損益試算 / 獲利率 columns rather than the gross gain.
- **Open vs closed status** — FIFO-matched per ticker: buys queue up; sells consume buy lots front-first; any buy lot with leftover shares is `open`, fully-consumed buys and all sells are `closed`.
- **Per-stock detail** — `/api/stock/{ticker}/detail` aggregates the live quote + yfinance fundamentals (1 h cache) + daily history + FinMind monthly revenue (TW) + yfinance quarterly financials (6 h cache) + your local trades / dividends in one call. The five upstream fetches run **concurrently**, so the modal loads in ~the slowest single call instead of the sum.
- **AI context** — every chat sends your full portfolio JSON + light fundamentals on every holding. If your question mentions a ticker, deep monthly revenue + quarterly margins for that ticker also get attached so the model can answer trend questions with citations.

### Live data flow

While a portfolio is on screen the app polls `/api/portfolio/{holdings,summary}` — every **5 s** while that market is open, **60 s** otherwise — and pauses when you leave the screen. Server-side quote caches (~5 s) absorb duplicate calls, and `names` is cached ~10 min so closed positions aren't re-fetched. Each market's open/closed status comes from the DB `markets` config (TW 09:00–13:30 Taipei, US 09:30–16:00 New York), editable without a redeploy.

Outside market hours MIS rolls `y` (yesterday's close) over to today's close, but the parser caches the last good quote per ticker and uses bid/ask midpoint / `o` (today's open) as fallbacks — so the TODAY column doesn't collapse to 0 % between trades.

---

## CSV import / export

The backend uses **one unified CSV** for both trades and dividends, via the `/api/data/export` and `/api/data/import` endpoints.

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
| POST   | /api/ai/chat                        | SSE stream (`init`→`chunk`→`done`); provider via `X-AI-Provider`/`X-AI-Key` (OpenAI / Gemini / Claude) |
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

The **Assistant** tab gives natural-language Q&A over your portfolio. Pick your provider — **OpenAI, Gemini, or Claude** — and use your own key. Gemini adds live Google-Search grounding with citations; all providers stream and render Markdown.

### What it knows

- Every open position with **light fundamentals** (sector, P/E, EPS, market cap, 52-week range, dividend yield, beta, 1-year analyst target, earnings / ex-div dates).
- Every trade and dividend you've recorded.
- For tickers you mention in the question (or in recent turns): **24 months of monthly revenue with YoY %** and **8 quarters of revenue / EPS / margins**.
- **Anything live on the web** via Gemini's built-in Google Search tool — recent news, regulatory filings, analyst commentary, macro events, conference call summaries.

This means questions like *"is 2330's gross margin improving?"* or *"compare 2330's price to its 1-year analyst target"* return tables with real numbers from your data — not generic boilerplate. Ask *"what's the latest news on 2330?"* and Gemini searches the web, writes a summary, and **inline citation chips** link each claim back to its source.

### Streaming + citations

- The backend streams Server-Sent Events: `init` → `chunk` (per token) → `done` (canonical content; Gemini adds `[N]` markers + a Sources block). It routes by `X-AI-Provider` / `X-AI-Key`; Gemini can fall back to the server's `GOOGLE_AI_API_KEY`.
- The iOS app consumes the stream with `URLSession.bytes`, renders partial **Markdown** live with an animated typing indicator, then swaps in the final content. Gemini citation source URLs are shortened to their domain.

### Persistent chat history

- The first user message becomes the chat title (auto-truncated).
- Tap the **history** button (top-left of the Assistant) for all saved chats with title, message count, and date. Tap a row to reopen it.
- **Swipe** a row to delete it, or use the **trash** button to clear them all.
- Tap **✎** (top-right) to start a fresh chat without losing your history.

### What it can / can't do

- ✅ Answer questions from your local data + per-ticker fundamentals (and, with Gemini, live web search).
- ✅ With Gemini, cite every web-sourced claim with a clickable inline link to its source.
- ✅ Stream responses token-by-token over SSE.
- ❌ Won't give buy/sell recommendations or price predictions, even when relaying analyst opinions found via search — those are framed as observations, never advice.

### Privacy tradeoff

When you ask a question, your portfolio JSON + ticker fundamentals are sent to your chosen provider (OpenAI / Gemini / Anthropic) for inference, using **your own key**; with Gemini it may also issue Google Search queries. Market quotes still happen on your backend. The assistant is entirely opt-in — with no provider key set it's disabled and the rest of the app works normally.

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
