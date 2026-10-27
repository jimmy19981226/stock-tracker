"""Agentic chat contracts using the real tool executor and an isolated ledger.

Only Gemini's transport is simulated; SSE, ownership checks, record proposals,
checked rendering and explicit record confirmation use the application code.
"""
import json
from unittest.mock import patch

from google.genai import types

from app.database import Dividend, Trade
from app.routers import ai
from app.services import ai_tools
from test_ai_features import AIFeatureFixture, OTHER, USER, model_chunk


def call(name, args, identifier=None):
    return model_chunk(types.Part(function_call=types.FunctionCall(
        name=name, args=args, id=identifier or name), thought_signature=b"test-signature"))


def reply(text="Review the confirmation card before saving."):
    return model_chunk(types.Part(text=text))


class AgenticChatTests(AIFeatureFixture):
    def ledger(self):
        with self.sessions() as db:
            return {
                "trades": [(r.id, r.user_id, ai_tools._trade_fields(r))
                           for r in db.query(Trade).order_by(Trade.id)],
                "dividends": [(r.id, r.user_id, ai_tools._dividend_fields(r))
                              for r in db.query(Dividend).order_by(Dividend.id)],
            }

    def actions(self, events):
        return [e["records"] for e in events if e["type"] == "action" and "records" in e]

    def test_every_record_write_tool_proposes_without_mutating_any_account(self):
        before = self.ledger()
        cases = [
            ("add_trade", {"ticker": "AAPL", "type": "buy", "shares": .75, "price": 199.5, "date": "2026-10-06"}, "trades", "create"),
            ("add_dividend", {"ticker": "AAPL", "amount": 12.34, "date": "2026-10-06"}, "dividends", "create"),
            ("update_trade", {"id": self.trade_ids[0], "price": 191.25}, "trades", "update"),
            ("update_dividend", {"id": self.dividend_ids[0], "amount": 55.75}, "dividends", "update"),
            ("delete_trade", {"id": self.trade_ids[0]}, "trades", "delete"),
            ("delete_dividend", {"id": self.dividend_ids[0]}, "dividends", "delete"),
        ]
        for tool, args, kind, operation in cases:
            with self.subTest(tool=tool):
                result, action = ai_tools.execute(tool, args, USER)
                self.assertEqual(result["status"], "proposed")
                self.assertIn("Nothing is saved", result["note"])
                self.assertEqual(action[kind][0]["op"], operation)
                self.assertEqual(self.ledger(), before)

    def test_proposal_is_streamed_before_answer_and_only_confirmation_changes_ledger(self):
        draft = {"ticker": "AAPL", "type": "buy", "shares": .75, "price": 199.5,
                 "fee": .25, "market": "US", "date": "2026-10-06"}
        self.fake_gemini([[call("add_trade", draft)], [reply()]])
        before = self.ledger()
        events = self.chat("Draft a purchase for review; do not save it yet.")
        proposals = self.actions(events)
        self.assertEqual(len(proposals), 1)
        self.assertEqual(self.ledger(), before)
        self.assertLess(next(i for i,e in enumerate(events) if e["type"] == "action"),
                        next(i for i,e in enumerate(events) if e["type"] == "chunk"))
        row = proposals[0]["trades"][0]
        body = {k: row[k] for k in ("ticker", "type", "shares", "price", "fee", "market", "notes")}
        body["trade_date"] = row["date"]
        confirmed = self.client.post("/api/trades", json=body)
        self.assertEqual(confirmed.status_code, 201, confirmed.text)
        after = self.ledger()
        self.assertEqual(len(after["trades"]), len(before["trades"])+1)
        self.assertEqual(after["dividends"], before["dividends"])
        self.assertEqual([r for r in after["trades"] if r[1] == OTHER],
                         [r for r in before["trades"] if r[1] == OTHER])

    def test_updates_and_deletes_cannot_propose_another_accounts_records(self):
        before = self.ledger()
        foreign_trade = next(r[0] for r in before["trades"] if r[1] == OTHER)
        foreign_dividend = next(r[0] for r in before["dividends"] if r[1] == OTHER)
        for tool, rid in [("update_trade", foreign_trade), ("delete_trade", foreign_trade),
                          ("update_dividend", foreign_dividend), ("delete_dividend", foreign_dividend)]:
            with self.subTest(tool=tool):
                result, action = ai_tools.execute(tool, {"id": rid, "price": 1, "amount": 1}, USER)
                self.assertIn("error", result)
                self.assertIsNone(action)
                self.assertNotIn("FOREIGN_RECORD", json.dumps(result))
                self.assertNotIn("MSFT", json.dumps(result))
        self.assertEqual(self.ledger(), before)

    def test_mixed_batch_flags_own_duplicates_and_skips_foreign_updates_without_writes(self):
        before = self.ledger()
        foreign_id = next(r[0] for r in before["trades"] if r[1] == OTHER)
        result, action = ai_tools.execute("propose_records", {
            "trades": [
                {"ticker": "AAPL", "type": "buy", "shares": 10.125, "price": 190.12, "date": "2026-08-01"},
                {"op": "update", "id": foreign_id, "price": 99},
                {"op": "update", "id": self.trade_ids[1], "price": 1001.5},
            ],
            "dividends": [{"op": "delete", "id": self.dividend_ids[0]},
                          {"ticker": "2330", "amount": 100, "date": "2026-10-06"}],
        }, USER)
        self.assertEqual(result["proposed"], {"trades": 2, "dividends": 2})
        self.assertEqual(result["duplicates_flagged"], 1)
        self.assertEqual(action["trades"][0]["duplicate_of"], self.trade_ids[0])
        self.assertEqual(action["trades"][1]["before"], {"price": 1000.0})
        self.assertEqual(action["trades"][1]["after"], {"price": 1001.5})
        self.assertEqual(len(result["skipped"]), 1)
        self.assertNotIn("FOREIGN_RECORD", json.dumps(action))
        self.assertEqual(self.ledger(), before)

    def test_same_day_round_trip_is_not_mistaken_for_a_duplicate_purchase(self):
        trade = {"ticker": "AAPL", "shares": 10.125, "price": 190.12, "date": "2026-08-01"}
        _, buy = ai_tools.execute("add_trade", {**trade, "type": "buy"}, USER)
        _, sell = ai_tools.execute("add_trade", {**trade, "type": "sell"}, USER)
        self.assertEqual(buy["trades"][0]["duplicate_of"], self.trade_ids[0])
        self.assertIsNone(sell["trades"][0]["duplicate_of"])

    def test_unknown_tool_is_recoverable_and_model_can_then_propose_valid_edit(self):
        requests = self.fake_gemini([
            [call("imaginary_tool", {})],
            [call("get_trades", {"ticker": "AAPL"})],
            [call("update_trade", {"id": self.trade_ids[0], "price": 191.25})],
            [reply()],
        ])
        before = self.ledger()
        events = self.chat("Correct the price on my AAPL purchase after checking the records.")
        self.assertIn("Unknown tool", requests[1]["contents"][-1].parts[0].function_response.response["result"]["error"])
        action = self.actions(events)[0]["trades"][0]
        self.assertEqual(action["id"], self.trade_ids[0])
        self.assertEqual(action["after"], {"price": 191.25})
        self.assertEqual(self.ledger(), before)

    def test_followup_carries_conversation_and_reads_fresh_data_after_confirmation(self):
        requests = self.fake_gemini([
            [call("get_trades", {"ticker": "AAPL"})], [reply("Your purchase is available for review.")],
            [call("get_trades", {"ticker": "AAPL"})],
            [call("answer_with_data", {"format": "json", "facts": [{"name": "price", "source_id": 1, "path": "trades.0.price"}]})],
        ])
        first = self.chat("Read my AAPL purchase.")
        with self.sessions() as db:
            record = db.get(Trade, self.trade_ids[0])
            record.price = 202.25
            db.commit()
        followup = self.chat("What is its price now? Reply only as JSON with price.", chat_id=first[0]["chat_id"])
        self.assertEqual([c.role for c in requests[2]["contents"]], ["user", "model", "user"])
        self.assertIn("AAPL", requests[2]["contents"][0].parts[0].text)
        self.assertEqual(json.loads(ai._META_HEADER_RE.sub("", followup[-1]["content"])), {"price": 202.25})
        stored = self.client.get(f"/api/ai/chats/{first[0]['chat_id']}").json()["messages"][-1]["content"]
        self.assertEqual(stored, followup[-1]["content"])

    def test_checked_table_is_currency_labeled_and_never_streams_model_guessed_numbers(self):
        self.fake_gemini([
            [call("get_holdings", {"market": "US"})],
            [reply("You hold 999999 shares worth USD 999999.")],
            [call("answer_with_data", {"format": "table", "facts": [
                {"name": "ticker", "source_id": 1, "path": "holdings.0.ticker"},
                {"name": "shares", "source_id": 1, "path": "holdings.0.shares"},
                {"name": "price", "source_id": 1, "path": "holdings.0.current_price"},
            ]})],
        ])
        events = self.chat("Show my US holdings as a concise table.")
        chunks = "".join(e["delta"] for e in events if e["type"] == "chunk")
        self.assertIn("| Metric | Value |", chunks)
        self.assertIn("10.125", chunks)
        self.assertIn("USD 200.125", chunks)
        self.assertIn("Figures checked against your app data.", chunks)
        self.assertNotIn("999999", chunks)
        self.assertNotIn("FOREIGN_RECORD", chunks)
        self.assertEqual(ai._META_HEADER_RE.sub("", events[-1]["content"]), chunks)

    def test_unavailable_tool_data_does_not_become_a_zero_or_fabricated_fact(self):
        requests = self.fake_gemini([
            [call("get_holdings", {"market": "US"})],
            [call("answer_with_data", {"facts": [{"name": "profit", "source_id": 1, "path": "error"}]})],
            [reply("The portfolio data is unavailable. Please try again shortly.")],
        ])
        with patch.object(ai_tools, "execute", return_value=({"error": "Market feed unavailable"}, None)):
            events = self.chat("What is my profit?")
        self.assertIn("failed tool result", requests[2]["contents"][-1].parts[0].function_response.response["result"]["error"])
        self.assertFalse(self.actions(events))
        self.assertIn("unavailable", events[-1]["content"])

    def test_create_proposals_reject_nonfinite_numbers_and_invalid_enum_values(self):
        base = {"ticker": "AAPL", "shares": 1, "price": 200, "type": "buy", "date": "2026-10-06"}
        for overrides in ({"shares": float("nan")}, {"price": float("inf")},
                          {"type": "transfer"}, {"market": "UNKNOWN"}, {"fee": -1}, {"date": "not-a-date"}):
            with self.subTest(overrides=overrides):
                result, action = ai_tools.execute("add_trade", {**base, **overrides}, USER)
                self.assertIn("error", result)
                self.assertIsNone(action)

    def test_batch_unknown_operation_cannot_silently_become_an_update(self):
        result, action = ai_tools.execute("propose_records", {"trades": [
            {"op": "replace_everything", "id": self.trade_ids[0], "price": 1},
        ]}, USER)
        self.assertIn("error", result)
        self.assertIsNone(action)

    def test_update_and_dividend_drafts_validate_values_before_emitting_cards(self):
        before = self.ledger()
        cases = [("update_trade", {"id": self.trade_ids[0], "shares": -1}),
                 ("update_trade", {"id": self.trade_ids[0], "price": float("nan")}),
                 ("update_dividend", {"id": self.dividend_ids[0], "amount": float("inf")}),
                 ("add_dividend", {"ticker": "AAPL", "amount": float("nan"), "date": "2026-10-06"}),
                 ("add_dividend", {"ticker": "AAPL", "amount": 1, "date": "invalid"})]
        for tool, args in cases:
            with self.subTest(tool=tool, args=args):
                result, action = ai_tools.execute(tool, args, USER)
                self.assertIn("error", result)
                self.assertIsNone(action)
        self.assertEqual(self.ledger(), before)

    def test_invalid_batch_rows_are_skipped_without_losing_valid_proposals(self):
        before = self.ledger()
        valid = {"ticker": "AAPL", "shares": .5, "price": 200, "date": "2026-10-06"}
        result, action = ai_tools.execute("propose_records", {
            "trades": [{**valid, "shares": "not-a-number"}, valid,
                       {"op": "update", "id": self.trade_ids[0], "price": float("inf")},
                       {"op": "unexpected", "id": self.trade_ids[0], "price": 1}, "not a row"],
            "dividends": [{"ticker": "AAPL", "amount": float("nan"), "date": "2026-10-06"},
                          {"ticker": "AAPL", "amount": 2, "date": "2026-10-06"}],
        }, USER)
        self.assertEqual(result["proposed"], {"trades": 1, "dividends": 1})
        self.assertEqual(len(result["skipped"]), 5)
        self.assertEqual(action["trades"][0]["shares"], .5)
        self.assertEqual(action["dividends"][0]["amount"], 2)
        json.dumps(action, allow_nan=False)
        self.assertEqual(self.ledger(), before)
