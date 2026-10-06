"""Exact dated returns through real account queries, pricing and AI tools."""
from datetime import date
from unittest import TestCase
from unittest.mock import patch

import pandas as pd
from google.genai import types

from app.database import Dividend, Trade
from app.routers import ai, portfolio as portfolio_router
from app.services import ai_tools, performance, portfolio, stock_info
from test_ai_features import AIFeatureFixture, USER, model_chunk


class FixedDate(date):
    @classmethod
    def today(cls):
        return cls(2026, 10, 6)


class PerformanceFixture(AIFeatureFixture):
    def setUp(self):
        super().setUp()
        self.client.app.include_router(portfolio_router.router)
        for module in (performance, portfolio, ai):
            self.stack.enter_context(patch.object(module, "date", FixedDate))
        self.stack.enter_context(patch.object(performance, "_cache", {}))
        self.stack.enter_context(patch.object(portfolio, "_value_history_cache", {}))
        dates = ["2026-09-01", "2026-09-21", "2026-09-22", "2026-09-23",
                 "2026-09-25", "2026-09-28", "2026-09-30", "2026-10-05",
                 "2026-10-06", "2026-10-07"]
        prices = {
            "AAPL": [100, 180, 200, 201, 210, 211, 205, 218, 220, 999],
            "2330": [900, 990, 1000, 1001, 1005, 1007, 1010, 1015, 1020, 9999],
            "^GSPC": [4000, 4990, 5000, 5001, 5005, 5007, 5025, 5040, 5050, 99999],
            "^TWII": [19000, 19990, 20000, 20001, 20005, 20007, 20025, 20040, 20050, 99999],
        }
        self.prices = {ticker: [{"date": d, "close": value} for d, value in zip(dates, values)]
                       for ticker, values in prices.items()}
        self.history_requests = []

        def history(ticker, period="1y", *, start_date=None, end_date=None):
            self.history_requests.append((ticker, period, start_date, end_date))
            return [b for b in self.prices.get(ticker, [])
                    if (start_date is None or b["date"] >= start_date)
                    and (end_date is None or b["date"] <= end_date)]

        self.stack.enter_context(patch.object(stock_info, "get_history", side_effect=history))

    def report(self, market="US", period="2w", **dates):
        result, action = ai_tools.execute("get_performance", {"market": market, "period": period,
                                                              **dates}, USER)
        self.assertIsNone(action)
        self.assertNotIn("error", result)
        return result["performance"]

    def replace_us_records(self, trades, dividends=()):
        with self.sessions() as db:
            for model in (Trade, Dividend):
                db.query(model).filter(model.user_id == USER, model.market == "US").delete()
            db.add_all([Trade(user_id=USER, ticker="AAPL", market="US", fee=0, **t)
                        for t in trades])
            db.add_all([Dividend(user_id=USER, ticker="AAPL", market="US", **d)
                        for d in dividends])
            db.commit()


class PerformanceTests(PerformanceFixture):
    def test_two_weeks_uses_the_exact_opening_value_and_only_needed_prices(self):
        us, tw = self.report(), self.report("TW")
        for result in (us, tw):
            self.assertEqual(result["status"], "ok")
            self.assertEqual((result["start_date"], result["end_date"]),
                             ("2026-09-22", "2026-10-06"))
            self.assertEqual(result["contributions"], 0)
            self.assertEqual(result["withdrawals"], 0)
        self.assertEqual((us["period_pl"], us["twr_pct"]), (202.5, 10.0))
        self.assertEqual((tw["period_pl"], tw["twr_pct"]), (2000.0, 2.0))
        self.assertEqual(us["benchmark"]["return_pct"], 1.0)
        self.assertAlmostEqual(sum(m["pl"] for m in us["monthly"]), us["period_pl"])
        self.assertEqual({r[0] for r in self.history_requests}, {"AAPL", "2330", "^GSPC", "^TWII"})
        self.assertTrue(all(start == "2026-09-08" and end == "2026-10-06"
                            for _, _, start, end in self.history_requests))

    def test_buys_sells_fees_and_weekend_dividends_are_cash_flows_not_returns(self):
        self.replace_us_records([
            {"type": "buy", "shares": 10, "price": 100, "trade_date": date(2026, 9, 1)},
            {"type": "buy", "shares": 5, "price": 100, "trade_date": date(2026, 9, 26)},
            {"type": "sell", "shares": 5, "price": 110, "trade_date": date(2026, 9, 30)},
        ], [{"amount": 3, "pay_date": date(2026, 10, 3)}])
        with self.sessions() as db:
            sale = db.query(Trade).filter(Trade.user_id == USER, Trade.type == "sell").one()
            sale.fee = 1
            db.commit()
        self.prices["AAPL"] = [{"date": d, "close": p} for d, p in (
            ("2026-09-22", 100), ("2026-09-25", 100), ("2026-09-28", 100),
            ("2026-09-30", 110), ("2026-10-05", 110), ("2026-10-06", 110))]
        result = self.report()
        self.assertEqual((result["opening_value"], result["closing_value"]), (1000, 1100))
        self.assertEqual((result["contributions"], result["withdrawals"]), (500, 552))
        self.assertEqual(result["period_pl"], 152)
        self.assertEqual(result["twr_pct"], 10.23)
        self.assertEqual(sum(m["pl"] for m in result["monthly"]), 152)

    def test_position_opened_inside_window_keeps_its_initial_purchase_and_fee(self):
        self.replace_us_records([
            {"type": "buy", "shares": 10, "price": 100, "trade_date": date(2026, 9, 25)},
        ])
        with self.sessions() as db:
            db.query(Trade).filter(Trade.user_id == USER, Trade.market == "US").one().fee = 1
            db.commit()
        self.prices["AAPL"] = [{"date": "2026-09-25", "close": 100},
                                {"date": "2026-10-06", "close": 110}]
        result = self.report()
        self.assertEqual((result["opening_value"], result["closing_value"]), (0, 1100))
        self.assertEqual((result["contributions"], result["period_pl"]), (1001, 99))
        self.assertEqual(result["twr_pct"], 9.89)

    def test_fully_sold_position_still_counts_toward_window_performance(self):
        self.replace_us_records([
            {"type": "buy", "shares": 10, "price": 100, "trade_date": date(2026, 9, 1)},
            {"type": "sell", "shares": 10, "price": 105, "trade_date": date(2026, 9, 30)},
        ])
        with self.sessions() as db:
            db.query(Trade).filter(Trade.user_id == USER, Trade.type == "sell").one().fee = 1
            db.commit()
        self.prices["AAPL"] = [{"date": "2026-09-22", "close": 100},
                                {"date": "2026-09-30", "close": 105},
                                {"date": "2026-10-06", "close": 110}]
        result = self.report()
        self.assertEqual((result["closing_value"], result["period_pl"], result["twr_pct"]),
                         (0, 49, 4.9))

    def test_explicit_dates_do_not_include_later_portfolio_or_benchmark_prices(self):
        result = self.report(start_date="2026-09-22", end_date="2026-09-30")
        self.assertEqual(result["period"], "custom")
        self.assertEqual(result["end_date"], "2026-09-30")
        self.assertEqual((result["period_pl"], result["twr_pct"]), (50.62, 2.5))
        self.assertEqual(result["benchmark"]["return_pct"], 0.5)
        self.assertTrue(all(r[3] == "2026-09-30" for r in self.history_requests))

    def test_weekend_opening_reports_the_actual_preceding_close(self):
        result = self.report(start_date="2026-09-26", end_date="2026-10-06")
        self.assertEqual(result["requested_start_date"], "2026-09-26")
        self.assertEqual(result["start_date"], "2026-09-25")
        self.assertEqual(result["period_pl"], 101.25)

    def test_missing_one_holdings_prices_cannot_produce_partial_totals(self):
        with self.sessions() as db:
            db.add(Trade(user_id=USER, type="buy", ticker="MSFT", market="US",
                         shares=1, price=100, fee=0, trade_date=date(2026, 9, 1)))
            db.commit()
        result = self.report()
        self.assertEqual(result["status"], "history_unavailable")
        self.assertIn("MSFT", result["reason"])
        self.assertIsNone(result["period_pl"])
        self.assertIsNone(result["twr_pct"])
        self.assertEqual(self.report("TW")["status"], "ok")

    def test_old_prices_are_not_substituted_for_the_requested_two_weeks(self):
        self.prices["AAPL"] = [{"date": "2026-09-10", "close": 100},
                                {"date": "2026-09-21", "close": 180}]
        result = self.report()
        self.assertEqual(result["status"], "insufficient_history")
        self.assertIsNone(result["period_pl"])
        self.assertEqual(result["portfolio_series"], [])

    def test_invalid_periods_or_dates_are_rejected_without_a_year_fallback(self):
        for params in ({"period": "2weeks"}, {"start_date": "2026-09-22"},
                       {"start_date": "2026-10-01", "end_date": "2026-09-01"},
                       {"start_date": "bad-date", "end_date": "2026-10-01"},
                       {"start_date": "2026-09-22", "end_date": "2026-10-07"}):
            with self.subTest(params=params):
                response = self.client.get("/api/portfolio/performance", params=params)
                self.assertEqual(response.status_code, 422)
        self.assertEqual(self.history_requests, [])
        response = self.client.get("/api/portfolio/performance", params={"market": "US", "period": "2w"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["period_pl"], 202.5)

    def test_rolling_window_cache_advances_on_the_next_date(self):
        first = self.report()
        requests = len(self.history_requests)
        self.assertEqual(self.report(), first)
        self.assertEqual(len(self.history_requests), requests)

        class NextDate(FixedDate):
            @classmethod
            def today(cls):
                return cls(2026, 10, 7)

        with patch.object(performance, "date", NextDate), patch.object(portfolio, "date", NextDate):
            result = self.report()
        self.assertEqual(result["requested_start_date"], "2026-09-23")
        self.assertEqual(result["requested_end_date"], "2026-10-07")
        self.assertGreater(len(self.history_requests), requests)

    def test_chat_receives_real_dated_returns_for_both_markets(self):
        parts = [types.Part(function_call=types.FunctionCall(
            name="get_performance", args={"market": market, "period": "2w"}, id=market),
            thought_signature=b"signed-state" if i == 0 else None)
                 for i, market in enumerate(("US", "TW"))]
        requests = self.fake_gemini([[model_chunk(*parts)],
                                    [model_chunk(types.Part(text="Two-week returns checked."))]])
        self.chat("How is my performance over this 2 weeks?")
        reports = [p.function_response.response["result"]["performance"]
                   for p in requests[1]["contents"][-1].parts]
        self.assertEqual([(r["currency"], r["period_pl"], r["twr_pct"]) for r in reports],
                         [("USD", 202.5, 10.0), ("TWD", 2000.0, 2.0)])


class HistoryRequestTests(TestCase):
    def test_dated_yahoo_request_includes_end_date_and_has_a_distinct_cache_key(self):
        frame = pd.DataFrame({"Open": [200, 220], "High": [201, 221],
                              "Low": [199, 219], "Close": [200, 220], "Volume": [1000, 2000]},
                             index=pd.to_datetime(["2026-09-22", "2026-10-06"]))
        with patch.object(stock_info, "_history_cache", {}), patch("yfinance.Ticker") as ticker:
            ticker.return_value.history.return_value = frame
            result = stock_info.get_history("AAPL", start_date="2026-09-08", end_date="2026-10-06")
            self.assertEqual(result[-1]["date"], "2026-10-06")
            ticker.return_value.history.assert_called_once_with(
                period=None, start="2026-09-08", end="2026-10-07", auto_adjust=False, timeout=8)
            stock_info.get_history("AAPL", start_date="2026-09-08", end_date="2026-10-06")
            self.assertEqual(ticker.return_value.history.call_count, 1)
            stock_info.get_history("AAPL", start_date="2026-09-08", end_date="2026-10-05")
            self.assertEqual(ticker.return_value.history.call_count, 2)
