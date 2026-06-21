# AI Stock Studio — Web Dashboard

A read-only portfolio dashboard that works on **phones and computers** over the
internet. Built with React + Vite, deployed to Vercel, talking to the FastAPI
backend on Render. Access is gated by a single shared password.

It shows: combined net worth (NT$ + US$), a "total earned" chart, per-market
(TW / US) summary cards, and the full holdings table with live prices. It is
strictly **read-only** — nothing here can edit your data.

## Local development

```bash
cd frontend
npm install
npm run dev          # http://localhost:5173
```

In dev, `/api/*` is proxied to the backend (default `http://127.0.0.1:8011`,
override with `VITE_DEV_API`). So run the backend locally too:

```bash
cd backend
WEB_DASHBOARD_PASSWORD=yourpassword python -m uvicorn app.main:app --port 8011
```

Then open http://localhost:5173 and sign in with `yourpassword`.

## Backend setup (required)

The dashboard needs two env vars on the backend (Render dashboard → Environment):

| Var | Purpose |
|-----|---------|
| `WEB_DASHBOARD_PASSWORD` | The password that unlocks the dashboard. **Required** — if unset, the dashboard shows "not enabled." |
| `WEB_DASHBOARD_USER_ID` | Which data scope the dashboard shows. Defaults to `legacy`. Set it to the user whose portfolio you want visible (e.g. `google:<sub>` if your data lives under a Google account). |

The login issues a stateless, signed, 12-hour token (HMAC keyed by the
password), so changing the password instantly invalidates every issued token.

## Deploy to Vercel

1. Push this repo to GitHub.
2. Vercel → **New Project** → import the repo.
3. Set **Root Directory** to `frontend`.
4. Framework preset: **Vite** (auto-detected; `vercel.json` also pins it).
5. Add an Environment Variable:
   - `VITE_API_BASE` = your Render URL, e.g. `https://ai-stock-studio.onrender.com`
6. Deploy. The same URL works on any phone or computer.

> **CORS:** the browser calls the backend cross-origin, so add your Vercel URL
> to the backend's `FRONTEND_ORIGINS` (comma-separated) env var on Render, e.g.
> `https://your-app.vercel.app`. Native apps aren't subject to CORS; browsers are.

## How auth works

```
POST /api/web/login  { password }      → { token, expires_in }   (password matches WEB_DASHBOARD_PASSWORD)
GET  /api/web/overview                 → portfolio overview        (Authorization: Bearer <token>)
GET  /api/web/holdings | summary | earnings-history | trades | dividends
```

All `/api/web/*` data endpoints require the bearer token and return data for
`WEB_DASHBOARD_USER_ID` only. See `backend/app/routers/webauth.py`.
