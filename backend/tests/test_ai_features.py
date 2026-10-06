"""Exercise app data and images through the chat API with an isolated database.

Market feeds and Gemini's network transport are replaced; database reads,
portfolio calculations, tool execution, image history, and SSE are real.
"""
import base64
import json
from contextlib import ExitStack
from copy import deepcopy
from datetime import date
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

from fastapi import FastAPI, Header
from fastapi.testclient import TestClient
from google.genai import types
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.auth import get_current_user
from app.database import Base, ChatMessage, Dividend, Trade, get_db
from app.routers import ai, dividends, trades
from app.services import ai_tools, markets, portfolio


USER = "google:feature-test"
OTHER = "google:other-test"
MODEL = "gemini-3.5-flash-lite"
IMAGE = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j8msAAAAASUVORK5CYII="
)


def model_chunk(*parts):
    return types.GenerateContentResponse(candidates=[
        types.Candidate(content=types.Content(role="model", parts=list(parts)))
    ])


class AIFeatureFixture(TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.engine = create_engine("sqlite://", poolclass=StaticPool,
                                    connect_args={"check_same_thread": False})
        self.addCleanup(self.engine.dispose)
        Base.metadata.create_all(self.engine)
        self.sessions = sessionmaker(bind=self.engine, autoflush=False)
        self.api_key = "test-key"
        for module in (ai, ai_tools, markets):
            self.stack.enter_context(patch.object(module, "SessionLocal", self.sessions))
        self.stack.enter_context(patch.object(ai, "_ctx_cache", {}))
        self.stack.enter_context(patch.object(ai, "_ctx_revisions", {}))
        self.stack.enter_context(patch.object(ai, "_runs", {}))
        self.stack.enter_context(patch.object(markets, "_cache", None))
        quote_map = {ticker: SimpleNamespace(price=price, previous_close=price - 1,
                                             name=ticker)
                     for ticker, price in (("AAPL", 200.125), ("2330", 1100.5),
                                           ("TSLA", 130), ("MSFT", 450))}
        self.stack.enter_context(patch.object(portfolio, "_get_quotes_shared",
                                               return_value=quote_map))
        self.stack.enter_context(patch.object(ai.quotes, "get_quote",
                                               side_effect=quote_map.get))
        self.stack.enter_context(patch.object(ai.quotes, "display_name",
                                               side_effect=lambda ticker, **_: ticker))
        self.stack.enter_context(patch.object(ai.stock_info, "get_fundamentals",
                                               return_value={"sector": "Technology", "pe": 25.5}))
        self.stack.enter_context(patch.object(ai.stock_info, "get_monthly_revenue",
                                               return_value=[{"month": "2026-08", "revenue": 123456789}]))
        self.stack.enter_context(patch.object(ai.stock_info, "get_quarterly_financials",
                                               return_value=[{"quarter": "2026-Q2", "revenue": 987654321}]))
        self.stack.enter_context(patch.object(ai_tools.fx, "get_usd_twd",
                                               return_value=(32.0, "2026-10-06")))
        with self.sessions() as db:
            own_trades = [
                Trade(user_id=USER, type="buy", ticker="AAPL", market="US",
                      shares=10.125, price=190.12, fee=2.31,
                      trade_date=date(2026, 8, 1), notes="Fractional US purchase"),
                Trade(user_id=USER, type="buy", ticker="2330", market="TW",
                      shares=100, price=1000, fee=142,
                      trade_date=date(2026, 7, 1), notes="Taiwan purchase"),
                Trade(user_id=USER, type="buy", ticker="TSLA", market="US",
                      shares=3, price=100, fee=1,
                      trade_date=date(2025, 1, 1), notes="Closed position"),
                Trade(user_id=USER, type="sell", ticker="TSLA", market="US",
                      shares=3, price=130, fee=1,
                      trade_date=date(2025, 2, 1), notes="Sold entire position"),
            ]
            own_dividends = [
                Dividend(user_id=USER, ticker="AAPL", market="US", amount=54.32,
                         pay_date=date(2026, 8, 15), notes="US payout"),
                Dividend(user_id=USER, ticker="2330", market="TW", amount=1234.56,
                         pay_date=date(2026, 7, 15), notes="Taiwan payout"),
            ]
            db.add_all(own_trades + own_dividends + [
                Trade(user_id=OTHER, type="buy", ticker="MSFT", market="US",
                      shares=999, price=450, fee=0,
                      trade_date=date(2026, 9, 1), notes="FOREIGN_RECORD"),
                Dividend(user_id=OTHER, ticker="MSFT", market="US", amount=99999,
                         pay_date=date(2026, 9, 1), notes="FOREIGN_RECORD"),
            ])
            db.commit()
            self.trade_ids = [t.id for t in own_trades]
            self.dividend_ids = [d.id for d in own_dividends]

        app = FastAPI()
        for router in (ai.router, trades.router, dividends.router):
            app.include_router(router)

        def test_user(authorization: str | None = Header(None)):
            return OTHER if authorization == "Bearer other" else USER

        def test_db():
            with self.sessions() as db:
                yield db

        app.dependency_overrides[get_current_user] = test_user
        app.dependency_overrides[get_db] = test_db
        self.client = self.stack.enter_context(TestClient(app))

    def snapshot(self, user=USER):
        return json.loads(ai._context_cached(user, []))

    def chat(self, message, chat_id=None, image=None):
        fields = {"message": message}
        if chat_id is not None:
            fields["chat_id"] = str(chat_id)
        response = self.client.post(
            "/api/ai/chat", data=fields,
            files={"file": ("statement.png", image, "image/png")} if image is not None else None,
            headers={"X-AI-Key": self.api_key, "X-AI-Provider": "gemini", "X-AI-Model": MODEL},
        )
        self.assertEqual(response.status_code, 200, response.text)
        events = [json.loads(line[6:]) for line in response.text.splitlines()
                  if line.startswith("data: ")]
        self.assertFalse([e for e in events if e["type"] == "error"], events)
        self.assertEqual(events[-1]["type"], "done", events)
        return events

    def fake_gemini(self, streams):
        requests = []
        responses = iter(streams)

        def generate(**kwargs):
            requests.append(deepcopy(kwargs))
            return iter(next(responses))

        client = SimpleNamespace(models=SimpleNamespace(generate_content_stream=generate))
        self.stack.enter_context(patch("google.genai.Client", return_value=client))
        return requests


class AIFeatureTests(AIFeatureFixture):
    def test_snapshot_includes_both_markets_all_history_and_precise_fields(self):
        context = self.snapshot()
        self.assertEqual({r["id"] for r in context["trades"]}, set(self.trade_ids))
        self.assertEqual({r["id"] for r in context["dividends"]}, set(self.dividend_ids))
        self.assertEqual({r["market"] for r in context["trades"]}, {"TW", "US"})
        self.assertEqual({r["market"] for r in context["dividends"]}, {"TW", "US"})
        self.assertEqual({r["currency"] for r in context["summary"]}, {"TWD", "USD"})
        self.assertNotIn("TSLA", {h["ticker"] for h in context["holdings"]})
        self.assertIn("TSLA", {t["ticker"] for t in context["trades"]})
        us = next(t for t in context["trades"] if t["ticker"] == "AAPL")
        self.assertEqual((us["shares"], us["price"], us["fee"]), (10.125, 190.12, 2.31))
        self.assertEqual(us["notes"], "Fractional US purchase")
        self.assertNotIn("FOREIGN_RECORD", json.dumps(context))
        self.assertNotIn("MSFT", json.dumps(context))
        with self.sessions() as db:
            focused = json.loads(ai._build_context(db, USER, ["2330"]))
        self.assertEqual(focused["focus"][0]["monthly_revenue"][0]["revenue"], 123456789)
        self.assertEqual(focused["focus"][0]["quarterly_financials"][0]["revenue"], 987654321)

    def test_chat_executes_real_portfolio_tools_for_the_authenticated_account(self):
        calls = [types.Part(function_call=types.FunctionCall(name=name, args={}, id=name),
                            thought_signature=b"signed-state" if i == 0 else None)
                 for i, name in enumerate(("get_portfolio_summary", "get_holdings",
                                            "get_trades", "get_dividends", "get_lots"))]
        requests = self.fake_gemini([
            [model_chunk(*calls)], [model_chunk(types.Part(text="Portfolio checked."))],
        ])
        events = self.chat("Read my holdings, all trades, dividends, and FIFO lots.")
        self.assertEqual(len(requests), 2)
        self.assertTrue(any(e["type"] == "status" and "holdings" in e["text"] for e in events))
        results = {p.function_response.name: p.function_response.response["result"]
                   for p in requests[1]["contents"][-1].parts}
        self.assertEqual({s["currency"] for s in results["get_portfolio_summary"]["summaries"]},
                         {"TWD", "USD"})
        self.assertEqual({t["id"] for t in results["get_trades"]["trades"]}, set(self.trade_ids))
        self.assertEqual({d["id"] for d in results["get_dividends"]["dividends"]}, set(self.dividend_ids))
        holdings = results["get_holdings"]["holdings"]
        us = next(h for h in holdings if h["ticker"] == "AAPL")
        self.assertEqual(us["shares"], 10.125)
        self.assertEqual(us["currency"], "USD")
        self.assertEqual(us["current_price"], 200.125)
        self.assertAlmostEqual(us["avg_cost"], 190.12 + 2.31 / 10.125)
        self.assertEqual({lot["ticker"] for lot in results["get_lots"]["lots"]}, {"AAPL", "2330"})
        self.assertNotIn("MSFT", json.dumps(results))
        self.assertNotIn("FOREIGN_RECORD", requests[0]["config"].system_instruction)

    def test_image_upload_reaches_gemini_and_survives_reload_and_followup(self):
        requests = self.fake_gemini([
            [model_chunk(types.Part(text="Image received."))],
            [model_chunk(types.Part(text="Follow-up received."))],
        ])
        events = self.chat("Read this image and compare it with my app records.", image=IMAGE)
        chat_id = events[0]["chat_id"]
        image_part = requests[0]["contents"][-1].parts[-1].inline_data
        self.assertEqual((image_part.mime_type, image_part.data), ("image/png", IMAGE))
        self.assertIn("Read this image", requests[0]["contents"][-1].parts[0].text)
        detail = self.client.get(f"/api/ai/chats/{chat_id}")
        self.assertEqual(detail.status_code, 200)
        data_url = detail.json()["messages"][0]["image"]
        self.assertEqual(base64.b64decode(data_url.split(",", 1)[1]), IMAGE)
        self.chat("What about the number in that same image?", chat_id=chat_id)
        contents = requests[1]["contents"]
        self.assertEqual([c.role for c in contents], ["user", "model", "user"])
        self.assertEqual(contents[0].parts[-1].inline_data.data, IMAGE)
        self.assertNotIn("<!--meta:", contents[1].parts[0].text)
        other = self.client.get(f"/api/ai/chats/{chat_id}", headers={"Authorization": "Bearer other"})
        self.assertEqual(other.status_code, 404)
        with self.sessions() as db:
            self.assertEqual(db.query(ChatMessage).filter(ChatMessage.chat_id == chat_id).count(), 4)

    def test_image_only_message_is_forwarded(self):
        requests = self.fake_gemini([[model_chunk(types.Part(text="Image received."))]])
        self.chat("", image=IMAGE)
        self.assertEqual(len(requests[0]["contents"][-1].parts), 1)
        self.assertEqual(requests[0]["contents"][-1].parts[0].inline_data.data, IMAGE)

    def test_trade_edits_refresh_warmed_context_immediately(self):
        self.snapshot()
        other_before = self.snapshot(OTHER)
        payload = {"type": "buy", "ticker": "AAPL", "shares": 0.125, "price": 123.45,
                   "fee": 0.12, "trade_date": "2026-10-01", "market": "US", "notes": "new lot"}
        response = self.client.post("/api/trades", json=payload)
        self.assertEqual(response.status_code, 201, response.text)
        record_id = response.json()["id"]
        new = next(t for t in self.snapshot()["trades"] if t["id"] == record_id)
        self.assertEqual(new["shares"], 0.125)
        payload["price"] = 234.56
        self.assertEqual(self.client.put(f"/api/trades/{record_id}", json=payload).status_code, 200)
        new = next(t for t in self.snapshot()["trades"] if t["id"] == record_id)
        self.assertEqual(new["price"], 234.56)
        self.assertEqual(self.client.delete(f"/api/trades/{record_id}").status_code, 204)
        self.assertNotIn(record_id, {t["id"] for t in self.snapshot()["trades"]})
        self.assertEqual(self.snapshot(OTHER), other_before)

    def test_dividend_edits_refresh_warmed_context_immediately(self):
        self.snapshot()
        payload = {"ticker": "2330", "amount": 111.25, "pay_date": "2026-10-01",
                   "market": "TW", "notes": "new payout"}
        response = self.client.post("/api/dividends", json=payload)
        self.assertEqual(response.status_code, 201, response.text)
        record_id = response.json()["id"]
        new = next(d for d in self.snapshot()["dividends"] if d["id"] == record_id)
        self.assertEqual(new["amount"], 111.25)
        payload["amount"] = 222.75
        self.assertEqual(self.client.put(f"/api/dividends/{record_id}", json=payload).status_code, 200)
        new = next(d for d in self.snapshot()["dividends"] if d["id"] == record_id)
        self.assertEqual(new["amount"], 222.75)
        self.assertEqual(self.client.delete(f"/api/dividends/{record_id}").status_code, 204)
        self.assertNotIn(record_id, {d["id"] for d in self.snapshot()["dividends"]})

    def test_edit_during_prewarming_does_not_cache_an_obsolete_snapshot(self):
        snapshots = iter(("old snapshot", "fresh snapshot"))

        def build(*args, **kwargs):
            context = next(snapshots)
            if context == "old snapshot":
                portfolio.invalidate_user(USER)
            return context

        with patch.object(ai, "_build_context", side_effect=build) as builder:
            self.assertEqual(ai._context_cached(USER, []), "old snapshot")
            self.assertEqual(ai._context_cached(USER, []), "fresh snapshot")
            self.assertEqual(ai._context_cached(USER, []), "fresh snapshot")
            self.assertEqual(builder.call_count, 2)

    def test_history_tools_can_read_every_filtered_record_without_sampling(self):
        with self.sessions() as db:
            own_trades, own_dividends = [], []
            for i in range(131):
                own_trades.append(Trade(user_id=USER, type="buy", ticker="AAPL", market="US",
                                        shares=0.125, price=123.45, fee=0.12,
                                        trade_date=date(2024, 1, 1), notes=f"Trade {i}: " + "記錄" * 250))
                own_dividends.append(Dividend(user_id=USER, ticker="AAPL", market="US",
                                              amount=1.23, pay_date=date(2024, 1, 1),
                                              notes=f"Dividend {i}: " + "記錄" * 250))
            db.add_all(own_trades + own_dividends + [
                Trade(user_id=OTHER, type="buy", ticker="AAPL", market="US", shares=999,
                      price=123.45, fee=0, trade_date=date(2024, 1, 1)),
                Dividend(user_id=OTHER, ticker="AAPL", market="US", amount=999,
                         pay_date=date(2024, 1, 1)),
            ])
            db.commit()
            expected = {"trades": [t.id for t in reversed(own_trades)],
                        "dividends": [d.id for d in reversed(own_dividends)]}
        for name, ids in expected.items():
            with self.subTest(tool=name):
                args = {"ticker": "AAPL", "market": "US", "year": 2024, "limit": 100}
                found, offsets = [], set()
                while True:
                    result, action = ai_tools.execute(f"get_{name}", args, USER)
                    self.assertIsNone(action)
                    self.assertEqual(result["total_count"], 131)
                    self.assertEqual(result["returned_count"], len(result[name]))
                    # The provider's result budget must not silently sample rows.
                    encoded = json.loads(ai_tools._result_json(result, f"get_{name}"))
                    self.assertEqual(encoded, result)
                    found.extend(r["id"] for r in encoded[name])
                    if not result["has_more"]:
                        self.assertIsNone(result["next_offset"])
                        break
                    self.assertNotIn(result["next_offset"], offsets)
                    offsets.add(result["next_offset"])
                    args["offset"] = result["next_offset"]
                self.assertEqual(found, ids)
                args["offset"] = 1000
                result, _ = ai_tools.execute(f"get_{name}", args, USER)
                self.assertEqual(result[name], [])
                self.assertFalse(result["has_more"])
