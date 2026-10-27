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
from app.services import ai_analytics, ai_answers, ai_tools
from test_ai_features import AIFeatureFixture, USER
from test_performance import FixedDate, PerformanceFixture


@skipUnless(os.environ.get("RUN_GEMINI_LIVE_TESTS") == "1",
            "Live Gemini testing requires an explicit opt-in and an API key")
class GeminiLiveFeatureTests(AIFeatureFixture):
    def setUp(self):
        super().setUp()
        config = dotenv_values(Path(__file__).resolve().parents[1] / ".env")
        self.api_key = os.environ.get("GOOGLE_AI_API_KEY") or config.get("GOOGLE_AI_API_KEY")
        if not self.api_key:
            self.fail("Configure GOOGLE_AI_API_KEY locally before running live tests")
        self.stack.enter_context(patch.object(ai_analytics, "date", FixedDate))

    def test_live_complete_filtered_totals_and_checked_answer(self):
        from datetime import date
        from app.database import Dividend

        with self.sessions() as db:
            db.add_all([Dividend(user_id=USER, ticker="AAPL", market="US", amount=0.1,
                                 pay_date=date(2026, 9, 15)) for _ in range(137)])
            db.commit()
        with patch.object(ai_tools, "execute", wraps=ai_tools.execute) as executed, \
             patch.object(ai_answers, "render", wraps=ai_answers.render) as checked:
            events = self.chat("What dividends did I receive last month in US dollars? Give the total and count, "
                               "including all payments. Reply only as JSON with amount, count, currency, start_date and end_date.")
        self.assertIn("get_record_summary", {c.args[0] for c in executed.call_args_list})
        self.assertTrue(checked.called)
        answer = json.loads(ai._META_HEADER_RE.sub("", events[-1]["content"]))
        self.assertEqual(answer, {"amount": 13.7, "count": 137, "currency": "USD",
                                  "start_date": "2026-09-01", "end_date": "2026-09-30"})
        print(f"Live Gemini complete dated dividend summary: {events[-1]['duration_ms']} ms")

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

    def test_live_synthetic_broker_screenshot_extracts_preview_without_saving(self):
        from PIL import Image, ImageDraw, ImageFont
        from app.database import Dividend, Trade

        image = Image.new("RGB", (650, 210), "white")
        draw = ImageDraw.Draw(image)
        for i, line in enumerate([
            "TAIWAN BROKER TRADE CONFIRMATION - SYNTHETIC TEST",
            "Market: Taiwan (TWD)   Stock code: 2330",
            "Trade: BUY   Date: 2026-10-06",
            "Shares: 100   Price per share (TWD): 1065.50",
            "Handling fee (TWD): 151.83   Transaction tax: 0.00",
            "No dividend records on this statement.",
        ]):
            draw.text((12, 12 + 28 * i), line, font=ImageFont.load_default(size=16), fill="black")
        encoded = io.BytesIO()
        image.resize((1300, 420), Image.Resampling.NEAREST).save(encoded, format="PNG")
        with self.sessions() as db:
            before = (db.query(Trade).count(), db.query(Dividend).count())
        with patch.dict(os.environ, {"GOOGLE_AI_API_KEY": self.api_key}):
            response = self.client.post("/api/ai/parse-records", files={
                "file": ("synthetic-broker.png", encoded.getvalue(), "image/png")})
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        self.assertEqual(len(result["trades"]), 1, result)
        self.assertEqual(result["dividends"], [], result)
        row = result["trades"][0]
        self.assertEqual({k: row[k] for k in ("ticker", "type", "shares", "price", "date", "fee")},
                         {"ticker": "2330", "type": "buy", "shares": 100, "price": 1065.5,
                          "date": "2026-10-06", "fee": 151.83})
        with self.sessions() as db:
            self.assertEqual((db.query(Trade).count(), db.query(Dividend).count()), before)

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


@skipUnless(os.environ.get("RUN_GEMINI_LIVE_TESTS") == "1",
            "Live Gemini testing requires an explicit opt-in and an API key")
class GeminiLivePerformanceTests(PerformanceFixture):
    def setUp(self):
        super().setUp()
        config = dotenv_values(Path(__file__).resolve().parents[1] / ".env")
        self.api_key = os.environ.get("GOOGLE_AI_API_KEY") or config.get("GOOGLE_AI_API_KEY")
        if not self.api_key:
            self.fail("Configure GOOGLE_AI_API_KEY locally before running live tests")
        self.stack.enter_context(patch.object(ai_analytics, "date", FixedDate))

    def test_live_period_comparison_uses_backend_difference(self):
        with patch.object(ai_tools, "execute", wraps=ai_tools.execute) as executed, \
             patch.object(ai_answers, "render", wraps=ai_answers.render) as checked:
            events = self.chat("How did my US portfolio do in the past fortnight versus the fortnight before it? "
                               "Reply only as JSON with current_profit, previous_profit, profit_change, "
                               "twr_change_percentage_points and currency.")
        self.assertIn("compare_performance", {c.args[0] for c in executed.call_args_list})
        self.assertTrue(checked.called)
        self.assertEqual(self.answer_json(events), {"current_profit": 202.5, "previous_profit": 1012.5,
                                                    "profit_change": -810.0, "twr_change_percentage_points": -90.0,
                                                    "currency": "USD"})
        print(f"Live Gemini period comparison: {events[-1]['duration_ms']} ms")

    def test_live_performance_explanation_uses_reconciled_contributors(self):
        with patch.object(ai_tools, "execute", wraps=ai_tools.execute) as executed, \
             patch.object(ai_answers, "render", wraps=ai_answers.render) as checked:
            events = self.chat("Which stocks caused my US portfolio's profit over these two weeks? "
                               "Reply only as JSON with ticker, profit, fees, dividends, reconciled and currency.")
        self.assertIn("get_performance_attribution", {c.args[0] for c in executed.call_args_list})
        self.assertTrue(checked.called)
        self.assertEqual(self.answer_json(events), {"ticker": "AAPL", "profit": 202.5, "fees": 0,
                                                    "dividends": 0, "reconciled": True, "currency": "USD"})
        print(f"Live Gemini performance attribution: {events[-1]['duration_ms']} ms")

    def answer_json(self, events):
        answer = ai._META_HEADER_RE.sub("", events[-1]["content"])
        match = re.search(r"\{.*\}", answer, re.DOTALL)
        self.assertIsNotNone(match, answer)
        return json.loads(match.group(0))

    def test_live_two_week_question_chooses_exact_performance_for_both_markets(self):
        with patch.object(ai_tools, "execute", wraps=ai_tools.execute) as executed:
            events = self.chat(
                "How is my performance over this 2 weeks? "
                "Reply only as JSON with US and TW objects containing currency, "
                "start_date, end_date, profit, and twr_pct."
            )
        calls = [c for c in executed.call_args_list if c.args[0] == "get_performance"]
        self.assertEqual({c.args[1]["market"] for c in calls}, {"US", "TW"})
        result = self.answer_json(events)
        self.assertEqual(result, {
            "US": {"currency": "USD", "start_date": "2026-09-22", "end_date": "2026-10-06",
                   "profit": 202.5, "twr_pct": 10.0},
            "TW": {"currency": "TWD", "start_date": "2026-09-22", "end_date": "2026-10-06",
                   "profit": 2000.0, "twr_pct": 2.0},
        })
        print(f"Live Gemini two-week performance reply: {events[-1]['duration_ms']} ms")

    def test_live_missing_history_does_not_block_the_other_market_or_invent_returns(self):
        self.prices["AAPL"] = []
        events = self.chat(
            "How is my performance over this 2 weeks? "
            "Reply only as JSON with US and TW objects containing profit, twr_pct, "
            "and reason. Use null for metrics when unavailable."
        )
        result = self.answer_json(events)
        self.assertIsNone(result["US"]["profit"])
        self.assertIsNone(result["US"]["twr_pct"])
        self.assertIn("AAPL", result["US"]["reason"])
        self.assertEqual(result["TW"]["profit"], 2000.0)
        self.assertEqual(result["TW"]["twr_pct"], 2.0)


@skipUnless(os.environ.get("RUN_GEMINI_LIVE_TESTS") == "1",
            "Live Gemini testing requires an explicit opt-in and an API key")
class GeminiLiveAgenticTests(AIFeatureFixture):
    """Real model/tool orchestration against a synthetic, disposable ledger."""
    def setUp(self):
        super().setUp()
        config = dotenv_values(Path(__file__).resolve().parents[1] / ".env")
        self.api_key = os.environ.get("GOOGLE_AI_API_KEY") or config.get("GOOGLE_AI_API_KEY")
        if not self.api_key:
            self.fail("Configure GOOGLE_AI_API_KEY locally before running live tests")

    def ledger(self):
        from app.database import Dividend, Trade
        with self.sessions() as db:
            return {
                "trades": [(r.id, r.user_id, ai_tools._trade_fields(r))
                           for r in db.query(Trade).order_by(Trade.id)],
                "dividends": [(r.id, r.user_id, ai_tools._dividend_fields(r))
                              for r in db.query(Dividend).order_by(Dividend.id)],
            }

    def proposal_rows(self, events, kind):
        return [row for event in events if event["type"] == "action"
                for row in event.get("records", {}).get(kind, [])]

    def test_live_create_and_followup_revision_remain_unconfirmed_drafts(self):
        before = self.ledger()
        first = self.chat("Prepare a trade for my review: bought 0.75 AAPL shares at US$199.50 "
                          "on 2026-10-06 with a US$0.25 fee. Do not save it; show the confirmation card.")
        rows = self.proposal_rows(first, "trades")
        self.assertTrue(rows, first[-1]["content"])
        row = rows[-1]
        self.assertEqual((row.get("op", "create"), row["ticker"], row["shares"], row["price"], row["date"], row["fee"]),
                         ("create", "AAPL", .75, 199.5, "2026-10-06", .25))
        self.assertEqual(self.ledger(), before)
        followup = self.chat("I have not confirmed that draft. Make it 1.25 shares instead, "
                             "with the same ticker, price, date and fee. Show the replacement draft card; don't edit an existing record.",
                             chat_id=first[0]["chat_id"])
        revised = self.proposal_rows(followup, "trades")
        self.assertTrue(revised, followup[-1]["content"])
        row = revised[-1]
        self.assertEqual((row.get("op", "create"), row["ticker"], row["shares"], row["price"], row["date"], row["fee"]),
                         ("create", "AAPL", 1.25, 199.5, "2026-10-06", .25))
        self.assertEqual(self.ledger(), before)
        print(f"Live Gemini draft and follow-up: {first[-1]['duration_ms']} / {followup[-1]['duration_ms']} ms")

    def test_live_edit_proposal_has_correct_before_after_and_does_not_save(self):
        before = self.ledger()
        record_id = self.trade_ids[0]
        events = self.chat(f"Correct my existing AAPL buy trade id {record_id}: its price should be US$191.25. "
                           "Read the record, show a before/after confirmation card, and change no other fields. Do not save yet.")
        rows = self.proposal_rows(events, "trades")
        self.assertTrue(rows, events[-1]["content"])
        row = rows[-1]
        self.assertEqual((row["op"], row["id"]), ("update", record_id))
        self.assertEqual(row["before"], {"price": 190.12})
        self.assertEqual(row["after"], {"price": 191.25})
        self.assertEqual(self.ledger(), before)
        print(f"Live Gemini edit proposal: {events[-1]['duration_ms']} ms")

    def test_live_delete_proposal_identifies_record_without_deleting(self):
        before = self.ledger()
        record_id = self.dividend_ids[0]
        events = self.chat(f"I want to delete my AAPL dividend payment id {record_id}. "
                           "Show the delete confirmation card identifying that payment. Do not delete it yet.")
        rows = self.proposal_rows(events, "dividends")
        self.assertTrue(rows, events[-1]["content"])
        row = rows[-1]
        self.assertEqual((row["op"], row["id"]), ("delete", record_id))
        self.assertEqual((row["record"]["ticker"], row["record"]["amount"]), ("AAPL", 54.32))
        self.assertEqual(self.ledger(), before)
        print(f"Live Gemini delete proposal: {events[-1]['duration_ms']} ms")

    def test_live_default_table_uses_checked_full_precision_and_currency(self):
        with patch.object(ai_answers, "render", wraps=ai_answers.render) as checked:
            events = self.chat("Show my current AAPL position as a concise Markdown table. "
                               "Include ticker, shares, current price and currency; preserve the app's exact values.")
        self.assertTrue(checked.called)
        answer = ai._META_HEADER_RE.sub("", events[-1]["content"])
        self.assertIn("| Metric | Value |", answer)
        self.assertIn("AAPL", answer)
        self.assertIn("10.125", answer)
        self.assertIn("200.125", answer)
        self.assertIn("USD", answer)
        self.assertIn("Figures checked against your app data.", answer)
        self.assertNotIn("FOREIGN_RECORD", answer)
        print(f"Live Gemini formatted position table: {events[-1]['duration_ms']} ms")
