# Stock Tracker

A self-hosted portfolio tracker for Taiwan and US equities. Manual trade entry,
live prices via Yahoo Finance, charts for performance and allocation.

## Stack

- **Backend** — FastAPI · SQLAlchemy · SQLite · `yfinance`
- **Frontend** — Vite · React · TypeScript · Recharts

## Project layout

```
backend/
  app/
    main.py            FastAPI app + CORS
    database.py        SQLAlchemy models, SQLite engine
    schemas.py         Pydantic request/response models
    routers/
      trades.py        CRUD for trades
      portfolio.py     holdings / summary / history / quote
    services/
      quotes.py        yfinance wrapper + ticker resolution + caching
      portfolio.py     avg-cost, realized P/L, daily value series
  data/trades.db       (auto-created)
frontend/
  src/
    App.tsx            shell + Dashboard / Trades views
    api.ts             typed fetch client
    format.ts          money / percent / TW-detection helpers
    components/        TradeForm, TradeList, PortfolioSummary,
                       HoldingsTable, AllocationChart, PerformanceChart
```

## Running locally

### Backend

```powershell
cd backend
pip install -r requirements.txt
python -m uvicorn app.main:app --reload --port 8000
```

API docs: http://127.0.0.1:8000/docs

### Frontend

```powershell
cd frontend
npm install
npm run dev
```

Open http://127.0.0.1:5173 — Vite proxies `/api/*` to the backend on `:8000`.

## How it works

- **Ticker resolution** — bare 4-6 digit codes (e.g. `2330`) are treated as
  Taiwan listings and queried as `2330.TW` against Yahoo Finance. Anything
  else (`AAPL`, `2330.TW`, `0050.TWO`) is passed through unchanged.
- **Currencies** — TW symbols report TWD, everything else USD. Holdings,
  summaries, and the value-over-time chart are kept separate per currency
  (no FX conversion).
- **Cost basis** — weighted-average cost. Sells reduce the open cost basis
  proportionally and realize the difference vs. average price (minus fees).
- **Caching** — quotes cached 60s, daily history 5min in-process. No DB
  cache, so restarting the backend re-fetches.

## Endpoints

| Method | Path                            | Purpose                          |
|--------|---------------------------------|----------------------------------|
| GET    | /api/health                     | liveness                         |
| GET    | /api/trades                     | list trades, newest first        |
| POST   | /api/trades                     | create a trade                   |
| DELETE | /api/trades/{id}                | delete a trade                   |
| GET    | /api/portfolio/holdings         | per-ticker open positions + P/L  |
| GET    | /api/portfolio/summary          | per-currency totals              |
| GET    | /api/portfolio/history?days=N   | daily portfolio value series     |
| GET    | /api/portfolio/quote/{ticker}   | spot quote (debug aid)           |
