"""Opt-in live Gemini UI test server with synthetic accounts and prices.

Run from the repo root: python3 ios/DesignPreview/live_ai_server.py
Only provider inference is live. Database and market data use test fixtures.
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Set before importing app code: backend/.env may point at production Neon.
os.environ["DATABASE_URL"] = "sqlite:///:memory:"
sys.path[:0] = [str(ROOT / "backend"), str(ROOT / "backend/tests")]

from dotenv import dotenv_values
import uvicorn
from unittest.mock import patch
from test_performance import PerformanceFixture, FixedDate
from app.services import ai_analytics

if __name__ == "__main__":
    key = os.environ.get("GOOGLE_AI_API_KEY") or dotenv_values(ROOT / "backend/.env").get("GOOGLE_AI_API_KEY")
    if not key:
        raise SystemExit("Configure GOOGLE_AI_API_KEY before running live UI tests.")
    os.environ["GOOGLE_AI_API_KEY"] = key
    fixture = PerformanceFixture()
    fixture.setUp()
    fixture.stack.enter_context(patch.object(ai_analytics, "date", FixedDate))
    print("Synthetic accounts and prices; live Gemini only. Listening on 127.0.0.1:8107.", flush=True)
    try:
        uvicorn.run(fixture.client.app, host="127.0.0.1", port=8107, log_level="warning")
    finally:
        fixture.doCleanups()
