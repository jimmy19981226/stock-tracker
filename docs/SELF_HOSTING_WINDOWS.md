# Self-hosting the backend on an always-on Windows machine

Goal: run the FastAPI backend on your Windows PC (pointing at your Neon
database), keep it running across reboots, and reach it from the iOS app
**anywhere** — including cellular — over a private Tailscale network.

```
iPhone (Tailscale app)  ──private mesh──►  Windows PC (Tailscale)
                                           └─ FastAPI :8011 ─► Neon Postgres
```

> ⚠️ The backend has **no authentication**. Do **not** expose it on the public
> internet (no port-forwarding, no public tunnel URL). Tailscale keeps it
> private to your own devices, which is exactly what you want here.

---

## A. Get the backend onto the Windows PC

1. **Install Python 3.11+** from <https://python.org> — tick *“Add Python to
   PATH”* during install.
2. **Install Git** from <https://git-scm.com> (or just copy the `backend\`
   folder over from your Mac).
3. Get the code, e.g.:
   ```bat
   git clone <your-repo-url> stock-tracker
   cd stock-tracker\backend
   ```
4. Install dependencies:
   ```bat
   python -m pip install -r requirements.txt
   ```
5. Create `backend\.env` with your Neon connection string (one line):
   ```
   DATABASE_URL=postgresql://neondb_owner:...@ep-...neon.tech/neondb?sslmode=require&channel_binding=require
   ```
6. Test it:
   ```bat
   run.bat
   ```
   Then browse to <http://localhost:8011/api/health> on the PC — you should see
   `{"status":"ok"}`. Press Ctrl+C to stop for now.

---

## B. Install Tailscale (PC + iPhone)

1. **Windows**: install from <https://tailscale.com/download> and sign in.
   Tailscale runs as a service and starts on boot automatically.
2. **iPhone**: install *Tailscale* from the App Store and sign in with the
   **same account**.
3. On the PC, find its Tailscale address:
   ```bat
   tailscale ip -4
   ```
   You'll get something like `100.101.102.103`. (Or use the MagicDNS name shown
   in the Tailscale admin console, e.g. `my-pc.tailXXXX.ts.net`.)

That `100.x.x.x` address is reachable from your iPhone over Tailscale from
anywhere — no firewall or router changes needed.

---

## C. Keep the backend running forever (Windows service)

So it survives reboots and runs without anyone logged in, wrap uvicorn in a
service with **NSSM** (Non-Sucking Service Manager):

1. Download NSSM from <https://nssm.cc/download>, unzip, and from that folder:
   ```bat
   nssm install StockTrackerAPI
   ```
2. In the dialog:
   - **Path**: full path to `python.exe`
     (run `where python` to find it, e.g. `C:\Python313\python.exe`)
   - **Startup directory**: your `...\stock-tracker\backend`
   - **Arguments**: `-m uvicorn app.main:app --host 0.0.0.0 --port 8011`
3. Click **Install service**, then start it:
   ```bat
   nssm start StockTrackerAPI
   ```
   It now starts automatically on every boot. (Manage it with
   `nssm restart/stop StockTrackerAPI`, or `services.msc`.)

> Allow the first-run Windows Firewall prompt for Python (private networks).
> Tailscale traffic is treated as a private network.

---

## D. Point the iOS app at it

1. Make sure Tailscale is **on** on the iPhone.
2. Open the app → **Portfolio tab → gear (Settings)**.
3. Set the backend URL to your PC's Tailscale address:
   ```
   http://100.101.102.103:8011
   ```
   (or `http://my-pc.tailXXXX.ts.net:8011` with MagicDNS)
4. Tap **Test connection** → should say **OK** → **Save**.

Your Mac and Render are no longer involved — the app talks straight to your
always-on PC, which talks to Neon.

---

## Notes

- **Running the app on a real iPhone** (not just the simulator) requires
  building/installing it from Xcode once, signed with your Apple ID (free
  accounts allow 7-day sideloads; a paid Apple Developer account lasts a year).
- To drop the “arbitrary HTTP loads” ATS exception later, serve the backend over
  HTTPS with `tailscale serve` and point the app at the `https://…ts.net` URL.
- Optional: also keep the **Neon** approach for the deployed Render backend — it
  reads the same database, so the app can fall back to it by changing the URL in
  Settings.
