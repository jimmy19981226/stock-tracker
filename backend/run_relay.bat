@echo off
REM ── Taiwan real-time quote relay ───────────────────────────────────────────
REM Run this on the machine whose connection TWSE accepts (your Taiwan IP).
REM It is read-only (live TW quotes only) and never touches the database.
REM
REM 1) Put your secret below (must match QUOTE_RELAY_SECRET set on Render).
REM 2) Double-click this file, then expose port 8500 with ngrok/cloudflared.
cd /d %~dp0

REM Prefer a secret already set in your environment (so you don't have to edit
REM — and risk committing — this file). Otherwise paste it on the line below.
if "%QUOTE_RELAY_SECRET%"=="" set QUOTE_RELAY_SECRET=PASTE_YOUR_SECRET_HERE

python -m uvicorn quote_relay:app --host 127.0.0.1 --port 8500
