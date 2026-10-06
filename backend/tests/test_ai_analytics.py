"""Known-answer checks for dated queries, explanations and verified answers."""
import json
from datetime import date
from unittest import TestCase
from unittest.mock import patch

from app.database import Dividend, Trade
from app.services import ai_analytics, ai_answers, ai_tools
from test_ai_features import OTHER, USER
from test_performance import FixedDate, PerformanceFixture


class AIAnalyticsTests(PerformanceFixture):
    def setUp(self):
        super().setUp()
        self.stack.enter_context(patch.object(ai_analytics, "date", FixedDate))

    def tool(self, name, **args):
        result, action = ai_tools.execute(name, args, USER)
        self.assertIsNone(action)
        self.assertNotIn("error", result)
        self.assertNotIn("FOREIGN_RECORD", json.dumps(result))
        return result

    def test_record_and_performance_calendar_bounds_are_distinct(self):
        records = self.tool("resolve_date_range", period="last_month")
        returns = self.tool("resolve_date_range", period="last_month", kind="performance")
        self.assertEqual((records["start_date"], records["end_date"]), ("2026-09-01", "2026-09-30"))
        self.assertEqual((returns["start_date"], returns["end_date"]), ("2026-08-31", "2026-09-30"))
        self.assertEqual(records["calendar_days"], 30)
        self.assertEqual(returns["calendar_days"], 30)
        self.assertTrue(records["start_inclusive"])
        self.assertFalse(returns["start_inclusive"])
        self.assertEqual(self.tool("resolve_date_range", period="2w")["start_date"], "2026-09-23")
        self.assertEqual(self.tool("resolve_date_range", period="2w", kind="performance")["start_date"], "2026-09-22")

    def test_filtered_record_pages_include_endpoints_and_exclude_other_users(self):
        with self.sessions() as db:
            db.add_all([Dividend(user_id=USER, ticker="AAPL", market="US", amount=amount, pay_date=day)
                        for day, amount in [(date(2026, 9, 1), 1), (date(2026, 9, 30), 2), (date(2026, 10, 1), 3)]])
            db.commit()
        first = self.tool("get_dividends", period="last_month", market="US", limit=1)
        self.assertEqual(first["total_count"], 2)
        self.assertEqual(first["dividends"][0]["amount"], 2)
        second = self.tool("get_dividends", period="last_month", market="US", offset=first["next_offset"])
        self.assertEqual(second["dividends"][0]["amount"], 1)
        self.assertFalse(second["has_more"])
        trades = self.tool("get_trades", start_date="2026-08-01", end_date="2026-08-01", ticker="AAPL")
        self.assertEqual(trades["total_count"], 1)
        self.assertEqual(trades["trades"][0]["shares"], 10.125)

    def test_summary_uses_old_fifo_cost_basis_and_preserves_currencies(self):
        with self.sessions() as db:
            db.query(Trade).filter(Trade.user_id == USER, Trade.market == "US").delete()
            db.query(Dividend).filter(Dividend.user_id == USER, Dividend.market == "US").delete()
            db.add_all([
                Trade(user_id=USER, type="buy", ticker="AAPL", market="US", shares=10, price=100, fee=2, trade_date=date(2026, 8, 1)),
                Trade(user_id=USER, type="sell", ticker="AAPL", market="US", shares=2, price=150, fee=1, trade_date=date(2026, 9, 15)),
                Dividend(user_id=USER, ticker="AAPL", market="US", amount=7.5, pay_date=date(2026, 9, 30)),
                Dividend(user_id=USER, ticker="2330", market="TW", amount=2000, pay_date=date(2026, 9, 30)),
            ])
            db.commit()
        summary = self.tool("get_record_summary", period="last_month", group_by="ticker")
        self.assertEqual(summary["matching_trade_count"], 1)
        us = next(t for t in summary["totals"] if t["currency"] == "USD")
        self.assertEqual((us["sell_net_proceeds"], us["realized_pl"], us["dividends"], us["cash_earned"]),
                         (299, 98.6, 7.5, 106.1))
        tw = next(t for t in summary["totals"] if t["currency"] == "TWD")
        self.assertEqual(tw["cash_earned"], 2000)
        self.assertEqual(us["buy_count"], 0)

    def test_summary_counts_all_records_and_does_not_sum_only_a_page(self):
        with self.sessions() as db:
            db.add_all([Dividend(user_id=USER, ticker=f"TEST{i:03}", market="US", amount=0.1,
                                 pay_date=date(2026, 9, 15)) for i in range(137)])
            db.commit()
        result = self.tool("get_record_summary", period="last_month", record_type="dividends", group_by="ticker", limit=2)
        total = next(row for row in result["totals"] if row["currency"] == "USD")
        self.assertEqual(total["dividends"], 13.7)
        self.assertEqual(total["dividend_count"], 137)
        self.assertEqual(len(result["groups"]), 2)
        self.assertTrue(result["complete_totals"])
        self.assertTrue(result["has_more"])
        self.assertEqual(result["next_offset"], 2)

    def test_empty_filter_has_canonical_zero_amounts_per_currency(self):
        result = self.tool("get_record_summary", period="last_month", market="US", record_type="dividends")
        self.assertEqual(result["totals"][0]["dividends"], 0)
        self.assertEqual(result["totals"][0]["currency"], "USD")
        self.assertEqual(result["matching_dividend_count"], 0)

    def test_year_filter_reports_its_actual_intersection_with_custom_dates(self):
        result = self.tool("get_record_summary", year=2026, end_date="2026-08-15", market="US")
        self.assertEqual((result["date_range"]["start_date"], result["date_range"]["end_date"]),
                         ("2026-01-01", "2026-08-15"))
        self.assertEqual(result["matching_trade_count"], 1)
        self.assertEqual(result["totals"][0]["dividends"], 54.32)

    def test_calendar_month_comparison_covers_the_whole_previous_month(self):
        result = self.tool("compare_performance", market="US", period="last_month")
        self.assertEqual((result["current"]["requested_start_date"], result["current"]["requested_end_date"]),
                         ("2026-08-31", "2026-09-30"))
        self.assertEqual((result["previous"]["requested_start_date"], result["previous"]["requested_end_date"]),
                         ("2026-07-31", "2026-08-31"))

    def test_comparison_uses_preceding_equal_duration_and_percentage_points(self):
        result = self.tool("compare_performance", market="US", period="2w")
        self.assertEqual(result["current"]["period_pl"], 202.5)
        self.assertEqual(result["previous"]["period_pl"], 1012.5)
        self.assertEqual(result["previous"]["requested_start_date"], "2026-09-08")
        self.assertEqual(result["previous"]["requested_end_date"], "2026-09-22")
        self.assertEqual(result["period_pl_change"], -810)
        self.assertEqual(result["twr_change_percentage_points"], -90)

    def test_missing_previous_history_does_not_become_zero(self):
        self.prices["AAPL"] = [b for b in self.prices["AAPL"] if b["date"] >= "2026-09-22"]
        result = self.tool("compare_performance", market="US", period="2w")
        self.assertEqual(result["current"]["status"], "ok")
        self.assertFalse(result["comparison_available"])
        self.assertIsNone(result["period_pl_change"])

    def test_attribution_reconciles_fractional_shares_and_excludes_old_closed_assets(self):
        result = self.tool("get_performance_attribution", market="US", period="2w")
        self.assertTrue(result["reconciled"])
        self.assertEqual(result["contributors_total_pl"], 202.5)
        self.assertEqual([c["ticker"] for c in result["contributors"]], ["AAPL"])
        self.assertEqual(result["contributors"][0]["opening_value"], 2025)
        self.assertEqual(result["contributors"][0]["closing_value"], 2227.5)

    def test_attribution_separates_cash_flows_fees_and_weekend_dividends(self):
        with self.sessions() as db:
            db.query(Trade).filter(Trade.user_id == USER, Trade.market == "US").delete()
            db.query(Dividend).filter(Dividend.user_id == USER, Dividend.market == "US").delete()
            db.add_all([
                Trade(user_id=USER, type="buy", ticker="AAPL", market="US", shares=10, price=100, fee=2, trade_date=date(2026, 9, 1)),
                Trade(user_id=USER, type="buy", ticker="AAPL", market="US", shares=5, price=210, fee=1, trade_date=date(2026, 9, 25)),
                Trade(user_id=USER, type="sell", ticker="AAPL", market="US", shares=5, price=205, fee=1, trade_date=date(2026, 9, 30)),
                Dividend(user_id=USER, ticker="AAPL", market="US", amount=3, pay_date=date(2026, 10, 3)),
            ])
            db.commit()
        result = self.tool("get_performance_attribution", market="US", period="2w")
        row = result["contributors"][0]
        self.assertTrue(result["reconciled"])
        self.assertEqual((row["gross_trading_price_pl"], row["fees"], row["dividends"], row["period_pl"]), (175, 2, 3, 176))
        self.assertEqual((row["buy_cost"], row["sell_net_proceeds"]), (1051, 1024))

    def test_attribution_includes_fully_sold_positions_and_later_paid_dividends(self):
        self.replace_us_records([
            {"type": "buy", "shares": 10, "price": 100, "trade_date": date(2026, 9, 1)},
            {"type": "sell", "shares": 10, "price": 205, "trade_date": date(2026, 9, 30)},
        ], [{"amount": 3, "pay_date": date(2026, 10, 3)}])
        result = self.tool("get_performance_attribution", market="US", period="2w")
        self.assertTrue(result["reconciled"])
        self.assertEqual(result["contributors_total_pl"], 53)
        self.assertEqual(result["contributors"][0]["closing_value"], 0)

    def test_inconsistent_contributor_prices_are_withheld(self):
        original = ai_analytics.stock_info.get_history.side_effect
        calls = []

        def inconsistent(ticker, *args, **kwargs):
            bars = original(ticker, *args, **kwargs)
            if ticker == "AAPL":
                calls.append(ticker)
                if len(calls) > 1:
                    bars = [{**bar, "close": 221} if bar["date"] == "2026-10-06" else bar for bar in bars]
            return bars

        with patch.object(ai_analytics.stock_info, "get_history", side_effect=inconsistent):
            result = self.tool("get_performance_attribution", market="US", period="2w")
        self.assertFalse(result["reconciled"])
        self.assertEqual(result["contributors"], [])
        self.assertIsNone(result["contributors_total_pl"])
        self.assertEqual(result["performance"]["period_pl"], 202.5)

    def test_invalid_dates_markets_and_groups_return_explicit_errors(self):
        for name, args in [("get_trades", {"start_date": "2026-10-06", "end_date": "2026-09-01"}),
                           ("get_dividends", {"end_date": "2027-01-01"}),
                           ("get_record_summary", {"market": "FOREIGN"}),
                           ("get_record_summary", {"group_by": "notes"}),
                           ("compare_performance", {"market": "US", "period": "max"})]:
            self.assertIn("error", ai_tools.execute(name, args, USER)[0])

    def test_relative_question_overrides_misguessed_model_dates(self):
        from google.genai import types
        from test_ai_features import model_chunk

        requests = self.fake_gemini([
            [model_chunk(types.Part(function_call=types.FunctionCall(name="get_record_summary", args={
                "market": "US", "record_type": "dividends", "start_date": "2026-08-01", "end_date": "2026-08-31"}, id="read")))],
            [model_chunk(types.Part(text="No payments in the requested month."))],
        ])
        self.chat("What dividends did I receive last month in US dollars?")
        result = requests[1]["contents"][-1].parts[0].function_response.response["result"]
        self.assertEqual(result["date_range"]["start_date"], "2026-09-01")
        self.assertEqual(result["date_range"]["end_date"], "2026-09-30")
        self.assertEqual(result["totals"][0]["dividends"], 0)

    def test_explicit_years_and_multiple_periods_are_not_overridden(self):
        args = {"start_date": "2025-08-01", "end_date": "2025-08-31"}
        self.assertEqual(ai_analytics.align_relative_window("get_record_summary", args, "Compare last month with this month"), args)
        self.assertEqual(ai_analytics.align_relative_window("get_record_summary", args, "Compare last month with August 2025"), args)


class CheckedAnswerTests(TestCase):
    def setUp(self):
        self.sources = {1: {"performance": {"currency": "USD", "period_pl": 1234567.89,
                                           "twr_pct": None, "start_date": "2026-09-22"},
                            "_evidence": {"tool": "get_performance", "retrieved_at": "2026-10-06 20:00:00 UTC"}}}

    def test_json_values_are_copied_from_sources_instead_of_accepted_from_model(self):
        args = {"format": "json", "facts": [
            {"name": "US.profit", "source_id": 1, "path": "performance.period_pl", "value": 999},
            {"name": "US.twr_pct", "source_id": 1, "path": "performance.twr_pct"},
        ]}
        self.assertEqual(json.loads(ai_answers.render(args, self.sources)), {"US": {"profit": 1234567.89, "twr_pct": None}})

    def test_table_keeps_full_numbers_and_freshness(self):
        answer = ai_answers.render({"facts": [{"name": "US_profit", "source_id": 1, "path": "performance.period_pl"}]}, self.sources)
        self.assertIn("1,234,567.89", answer)
        self.assertIn("2026-10-06 20:00:00 UTC", answer)
        self.assertNotIn("1.2M", answer)
        self.assertIn("USD 1,234,567.89", answer)
        self.assertIn("Profit or loss", answer)

    def test_table_labels_percentage_points_without_converting_them_to_percent_growth(self):
        source = {1: {"twr_change_percentage_points": -3.25, "_evidence": self.sources[1]["_evidence"]}}
        answer = ai_answers.render({"facts": [{"name": "return_change", "source_id": 1,
                                                "path": "twr_change_percentage_points"}]}, source)
        self.assertIn("-3.25 percentage points", answer)

    def test_unknown_sources_arithmetic_paths_duplicate_keys_and_unchecked_prose_are_rejected(self):
        good = {"name": "profit", "source_id": 1, "path": "performance.period_pl"}
        for args in [{"facts": [{**good, "source_id": 2}]},
                     {"facts": [{**good, "path": "performance.period_pl * 2"}]},
                     {"facts": [good, good]},
                     {"facts": [good], "explanation": "You made $999."},
                     {"facts": [{**good, "path": "performance"}]}]:
            with self.assertRaises(ValueError):
                ai_answers.render(args, self.sources)

    def test_requested_json_fields_are_enforced_and_not_taken_from_tool_path_names(self):
        args = {"facts": [{"name": "performance.period_pl", "source_id": 1, "path": "performance.period_pl"}]}
        with self.assertRaisesRegex(ValueError, "exactly these requested JSON"):
            ai_answers.render(args, self.sources, "Reply only as JSON with profit.")
        args["facts"][0]["name"] = "profit"
        self.assertEqual(json.loads(ai_answers.render(args, self.sources, "Reply only as JSON with profit.")), {"profit": 1234567.89})
        self.assertEqual(ai_answers.requested_json_fields("Reply only as JSON with US and TW objects containing currency, profit and reason."),
                         ["US.currency", "US.profit", "US.reason", "TW.currency", "TW.profit", "TW.reason"])

    def test_filtered_counts_cannot_be_labeled_as_whole_account_counts(self):
        source = {1: {"total_count": 3, "_evidence": {**self.sources[1]["_evidence"], "filters": {"market": "US"}}}}
        with self.assertRaisesRegex(ValueError, "Whole-account counts"):
            ai_answers.render({"facts": [{"name": "trade_count", "source_id": 1, "path": "total_count"}]},
                              source, "Check all my records in both markets. Reply as JSON with trade_count.")
