@echo off
REM Start the FastAPI backend on this machine, reachable on the LAN/Tailscale.
REM Reads DATABASE_URL from backend\.env (your Neon connection string).
cd /d %~dp0
python -m uvicorn app.main:app --host 0.0.0.0 --port 8011
