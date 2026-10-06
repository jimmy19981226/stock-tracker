"""Opt-in live Gemini checks using synthetic data, never the production DB.

Set RUN_GEMINI_LIVE_TESTS=1 and configure GOOGLE_AI_API_KEY in the environment
or backend/.env. Ordinary test runs skip these network calls.
"""
import io
import json
import os
import re
from pathlib import Path
from unittest import skipUnless
from unittest.mock import patch

from dotenv import dotenv_values

from app.routers import ai
from app.services import ai_tools
from test_ai_features import AIFeatureFixture


@skipUnless(os.environ.get("RUN_GEMINI_LIVE_TESTS") == "1",
            "Live Gemini testing requires an explicit opt-in and an API key")
class GeminiLiveFeatureTests(AIFeatureFixture):
    def setUp(self):
        super().setUp()
        config = dotenv_values(Path(__file__).resolve().parents[1] / ".env")
        self.api_key = os.environ.get("GOOGLE_AI_API_KEY") or config.get("GOOGLE_AI_API_KEY")
        if not self.api_key:
            self.fail("Configure GOOGLE_AI_API_KEY locally before running live tests")

    def test_live_portfolio_tools_return_the_accounts_actual_values(self):
        with patch.object(ai_tools, "execute", wraps=ai_tools.execute) as executed:
            events = self.chat(
                "Call get_trades and get_dividends to check all my records in both markets. "
                "Then reply only with JSON containing trade_count, dividend_count, "
                "aapl_shares (my current shares), us_dividend (my AAPL payment), "
                "and twd_dividend (my 2330 payment). No Markdown or commentary."
            )
        called = {call.args[0] for call in executed.call_args_list}
        self.assertTrue({"get_trades", "get_dividends"}.issubset(called), called)
        answer = ai._META_HEADER_RE.sub("", events[-1]["content"])
        match = re.search(r"\{.*\}", answer, re.DOTALL)
        self.assertIsNotNone(match, answer)
        result = json.loads(match.group(0))
        self.assertEqual(result, {"trade_count": 4, "dividend_count": 2,
                                  "aapl_shares": 10.125, "us_dividend": 54.32,
                                  "twd_dividend": 1234.56})
        print(f"Live Gemini portfolio reply: {events[-1]['duration_ms']} ms")

    def test_live_image_reading_and_followup(self):
        from PIL import Image, ImageDraw, ImageFont

        image = Image.new("RGB", (250, 55), "white")
        ImageDraw.Draw(image).text((9, 18), "IMAGE CODE: ORCHID-7429",
                                  font=ImageFont.load_default(), fill="black")
        image = image.resize((1000, 220), Image.Resampling.NEAREST)
        encoded = io.BytesIO()
        image.save(encoded, format="PNG")
        events = self.chat("Read the code printed after IMAGE CODE. Reply only with that code.",
                           image=encoded.getvalue())
        self.assertIn("ORCHID-7429", events[-1]["content"])
        followup = self.chat("What was the code in that image? Reply only with that code.",
                             chat_id=events[0]["chat_id"])
        self.assertIn("ORCHID-7429", followup[-1]["content"])
        print(f"Live Gemini image reply: {events[-1]['duration_ms']} ms")
