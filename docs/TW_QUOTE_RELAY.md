# Real-time Taiwan quotes — the quote relay

Render (US) can't fetch live Taiwan prices, because **TWSE only answers requests
from a Taiwan-accepted IP**. The relay (`backend/quote_relay.py`) runs on a
machine that *does* have such a connection, and Render calls it just for the TW
price hop. It's read-only and never touches the database; if it's ever down,
Render automatically falls back to (delayed) Yahoo quotes.

```
iPhone ─► Render backend ─► quote relay (your TW machine) ─► TWSE (live TW prices)
                        └─► Yahoo (US prices + TW fallback)
```

You only need this for **real-time TW prices**. Without it everything still
works; TW prices are just ~15–20 min delayed.

---

## Your secret

Generate a random shared secret and use the **same** value in both places below
(the relay machine and Render). **Don't commit it to git.**

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

Call the result `<YOUR_RELAY_SECRET>` below.

---

## A. On the relay machine (Windows)

1. Get the `backend/` folder onto the machine and install deps once:
   ```bat
   cd path\to\stock-tracker\backend
   python -m pip install -r requirements.txt
   ```
2. Edit **`run_relay.bat`** and paste the secret into `QUOTE_RELAY_SECRET=`.
3. Start the relay:
   ```bat
   run_relay.bat
   ```
   Check it locally: open <http://localhost:8500/health> →
   `{"status":"ok","secret_required":true}`.

## B. Give it a stable public URL (ngrok)

The relay must be reachable from Render. ngrok's free plan includes **one static
domain**, so the URL doesn't change on restart.

1. Install ngrok (<https://ngrok.com/download>), sign in, and grab your free
   static domain from the ngrok dashboard (e.g. `your-name.ngrok-free.app`).
2. In a second terminal:
   ```bat
   ngrok http --domain=your-name.ngrok-free.app 8500
   ```
   Your relay URL is now `https://your-name.ngrok-free.app`.

   > Cloudflare Tunnel works too (`cloudflared tunnel --url http://localhost:8500`),
   > but its free *quick* tunnels get a new random URL each restart, so you'd have
   > to update Render every time — ngrok's static domain avoids that.

## C. Tell Render to use the relay

In the **Render dashboard → `stock-tracker-api` → Environment**, add two vars:

| Key | Value |
|-----|-------|
| `QUOTE_RELAY_URL` | `https://your-name.ngrok-free.app` |
| `QUOTE_RELAY_SECRET` | `<YOUR_RELAY_SECRET>` |

Save — Render redeploys automatically. Done: TW quotes now come live through your
relay.

## D. Verify

- Relay reachable from outside: open `https://your-name.ngrok-free.app/health`
  in a browser → `{"status":"ok",...}`.
- After Render restarts, TW prices in the app should match the live market
  during TW trading hours (09:00–13:30 Taipei) instead of lagging.

---

## Keep it always-on (Windows services)

So the relay + tunnel survive reboots without anyone logged in:

- **Relay** — wrap it with [NSSM](https://nssm.cc):
  `nssm install StockTrackerRelay` → Path = your `python.exe`,
  Startup dir = `...\backend`,
  Arguments = `-m uvicorn quote_relay:app --host 127.0.0.1 --port 8500`.
  Add an Environment entry `QUOTE_RELAY_SECRET=<secret>` on the *Environment* tab.
- **ngrok** — install it as a service: `ngrok service install` then
  `ngrok service start` (configure the tunnel in ngrok's `ngrok.yml`).

---

## Security note

The relay is read-only and gated by the secret header, so even though the ngrok
URL is public, only callers with `QUOTE_RELAY_SECRET` (i.e. your Render backend)
can use your connection. Keep the secret out of git — it only lives in
`run_relay.bat` (local) and Render's env vars.
