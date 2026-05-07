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

## CSV import / export

The app uses **one unified CSV** for both trades and dividends. The header bar
has **⤓ Export** and **⤒ Import** buttons that download / upload it.

Each row's `kind` column tells the backend whether it's a trade or a
dividend, and the kind-specific fields are filled in only as relevant:

```
kind,type,ticker,shares,price,date,fee,amount,notes
trade,buy,2330,100,950,2024-01-15,28,,initial buy
trade,sell,2330,100,1100,2024-06-01,30,,closed
dividend,,2330,,,2024-08-15,,5,Q2 cash dividend
```

- For `kind=trade`: `type` (buy/sell), `shares`, `price`, `date`, `fee`, `notes` (optional). `amount` is empty.
- For `kind=dividend`: `ticker`, `date`, `amount`, `notes` (optional). The trade-specific columns are empty.
- Dates accept `YYYY-MM-DD`, `YYYY/MM/DD`, or `MM/DD/YYYY`.
- Import always **appends** rows. To replace your data, delete from the UI first or remove `backend/data/trades.db`.

### Auto-seed on first boot

Drop a file at `backend/data/seed/portfolio.csv` and the backend loads it on
startup — **but only when both tables are empty.**

- First boot with no DB: the seed file is imported automatically.
- Once you have any data: the seed file is ignored (UI-entered data is never overwritten).
- To re-seed: delete `backend/data/trades.db`, then restart the backend.

## Endpoints

| Method | Path                                | Purpose                                  |
|--------|-------------------------------------|------------------------------------------|
| GET    | /api/health                         | liveness                                 |
| GET    | /api/trades                         | list trades, newest first                |
| POST   | /api/trades                         | create a trade                           |
| DELETE | /api/trades/{id}                    | delete a trade                           |
| GET    | /api/dividends                      | list dividends, newest first             |
| POST   | /api/dividends                      | create a dividend                        |
| DELETE | /api/dividends/{id}                 | delete a dividend                        |
| GET    | /api/data/export                    | download unified portfolio CSV           |
| POST   | /api/data/import                    | upload unified CSV (trades + dividends)  |
| GET    | /api/portfolio/holdings             | per-ticker open positions + P/L          |
| GET    | /api/portfolio/summary              | per-currency totals incl. dividends      |
| GET    | /api/portfolio/history?days=N       | daily market value series (open holdings)|
| GET    | /api/portfolio/realized-history?days=N | daily cumulative realized P/L          |
| GET    | /api/portfolio/quote/{ticker}       | spot quote (debug aid)                   |
