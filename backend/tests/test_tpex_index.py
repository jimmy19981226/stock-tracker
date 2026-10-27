"""Official OTC index mapping and data integrity; all network calls are mocked."""
from datetime import date
from unittest import TestCase
from unittest.mock import MagicMock, patch

from app.routers import indices, stock
from app.services import quotes, stock_info, tpex_index, yahoo_quotes


def bar(day, close=379.2):
    return dict(date=day, open=383.88, high=388.39, low=375.73, close=close, volume=None)


class TPExIndexTests(TestCase):
    def setUp(self):
        self.cache = patch.object(tpex_index, "_cache", {})
        self.cache.start()
        self.addCleanup(self.cache.stop)

    def test_official_intraday_mapping_keeps_previous_close_and_source_date(self):
        payload = {"msgArray": [{"ch": "o00.tw", "z": "379.20", "y": "381.69", "d": "20261027",
                                 "o": "383.88", "h": "388.39", "l": "375.73"}]}
        with patch.object(tpex_index, "_fetch_json", return_value=payload) as fetch:
            quote = tpex_index.get_quote()
        self.assertIn("ex_ch=otc_o00.tw", fetch.call_args.args[0])
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual((quote.symbol, quote.currency, quote.price, quote.previous_close),
                         ("^TWOII", "TWD", 379.2, 381.69))
        self.assertEqual((quote.source, quote.as_of), ("TWSE MIS", "2026-10-27"))
        self.assertEqual((quote.day_open, quote.day_high, quote.day_low), (383.88, 388.39, 375.73))

    def test_unavailable_or_malformed_mis_falls_back_to_latest_dated_official_close(self):
        history = [{"Date": "20261027", "Close": "379.20", "Change": "-2.49"},
                   {"Date": "20261001", "Close": "418.82", "Change": "1.75"},
                   {"Date": "garbage", "Close": "9000"}, {"Date": "20261028", "Close": "NaN"}, None]
        for mis in (None, {"msgArray": None}, {"msgArray": {}},
                    {"msgArray": [{"ch": "o00.tw", "z": "-", "d": "20261027"}]},
                    {"msgArray": [{"ch": "o00.tw", "z": "500", "d": "invalid"}]}):
            with self.subTest(mis=mis), patch.object(tpex_index, "_cached", side_effect=[mis, history]):
                quote = tpex_index.get_quote()
                self.assertEqual(quote.price, 379.2)
                self.assertAlmostEqual(quote.previous_close, 381.69)
                self.assertEqual((quote.as_of, quote.source), ("2026-10-27", "TPEx close"))

    def test_bad_quote_fields_never_turn_into_zero_or_infinite_prices(self):
        with patch.object(tpex_index, "_cached", side_effect=[{}, [{"Date": "20261027", "Close": "Infinity"}]]):
            self.assertIsNone(tpex_index.get_quote())
        with patch.object(tpex_index, "_cached", side_effect=[{}, [{"Date": "20261027", "Close": "379.20"}]]):
            self.assertIsNone(tpex_index.get_quote().previous_close)
        with patch.object(tpex_index, "_cached", side_effect=[{}, [{"Date": "20261027", "Close": "379.20", "Change": "999"}]]):
            self.assertIsNone(tpex_index.get_quote().previous_close)

    def test_monthly_parser_uses_ohlc_rows_and_rejects_other_months_and_invalid_closes(self):
        payload = {"stat": "ok", "tables": [{"data": [
            ["2026/10/27", "383.88", "388.39", "375.73", "379.20", "-2.49"],
            ["2026/09/30", "1", "2", "1", "2", "1"],
            ["2026/10/28", "1", "2", "1", "NaN", "1"], None, ["bad"],
        ]}]}
        with patch.object(tpex_index, "_cached", return_value=payload):
            self.assertEqual(tpex_index._month_history(date(2026, 10, 1)), [bar("2026-10-27")])

    def test_malformed_month_containers_are_unavailable_but_empty_valid_month_is_allowed(self):
        for payload in (None, [], {"tables": None}, {"stat": "ok", "tables": [None]},
                        {"stat": "ok", "tables": [{"data": None}]}, {"stat": "error", "tables": []}):
            with self.subTest(payload=payload), patch.object(tpex_index, "_cached", return_value=payload):
                self.assertIsNone(tpex_index._month_history(date(2026, 10, 1)))
        with patch.object(tpex_index, "_cached", return_value={"stat": "ok", "tables": [{"data": []}]}):
            self.assertEqual(tpex_index._month_history(date(2026, 10, 1)), [])

    def test_rolling_month_crosses_month_boundary_and_sorts_deduplicates_filters(self):
        pages = {date(2026, 9, 1): [bar("2026-09-26"), bar("2026-09-30", 417.07), bar("2026-09-27", 410)],
                 date(2026, 10, 1): [bar("2026-10-28"), bar("2026-10-27"), bar("2026-10-01", 418.82), bar("2026-10-01", 418.82)]}
        with patch.object(tpex_index, "_month_history", side_effect=pages.get) as fetch:
            result = tpex_index.get_history("1mo", end_date="2026-10-27")
        self.assertEqual({c.args[0] for c in fetch.call_args_list}, set(pages))
        self.assertEqual([b["date"] for b in result], ["2026-09-27", "2026-09-30", "2026-10-01", "2026-10-27"])

    def test_explicit_dates_are_inclusive_and_failed_month_cannot_be_hidden(self):
        with patch.object(tpex_index, "_month_history", return_value=[bar("2026-10-01"), bar("2026-10-06"), bar("2026-10-07")]):
            result = tpex_index.get_history("max", start_date="2026-10-01", end_date="2026-10-06")
        self.assertEqual([b["date"] for b in result], ["2026-10-01", "2026-10-06"])
        with patch.object(tpex_index, "_month_history", side_effect=lambda month: None if month.month == 9 else [bar("2026-10-27")]):
            self.assertEqual(tpex_index.get_history("1mo", end_date="2026-10-27"), [])
        with patch.object(tpex_index, "_month_history") as fetch:
            self.assertEqual(tpex_index.get_history("max", end_date="2026-10-27"), [])
            self.assertEqual(tpex_index.get_history(start_date="2026-10-28", end_date="2026-10-27"), [])
            self.assertEqual(tpex_index.get_history(start_date="2000-01-01", end_date="2026-10-27"), [])
            fetch.assert_not_called()

    def test_failed_historical_fetch_is_retried_after_short_negative_cache(self):
        with patch.object(tpex_index.time, "monotonic", side_effect=[100, 110, 131]), \
             patch.object(tpex_index, "_fetch_json", side_effect=[TimeoutError(), {"recovered": True}]) as fetch:
            self.assertIsNone(tpex_index._cached("synthetic-month", 86400))
            self.assertIsNone(tpex_index._cached("synthetic-month", 86400))
            self.assertEqual(tpex_index._cached("synthetic-month", 86400), {"recovered": True})
            self.assertEqual(fetch.call_count, 2)

    def test_quote_and_history_dispatch_never_send_otc_symbol_to_yahoo(self):
        quote = quotes.QuoteData("^TWOII", 379.2, 381.69, "TWD", "櫃買指數")
        token = quotes.source_preference.set("yahoo")
        try:
            with patch.object(tpex_index, "get_quote", return_value=quote), \
                 patch.object(yahoo_quotes, "get_quotes", return_value={}) as yahoo:
                self.assertEqual(quotes.get_quotes(["^TWOII"]), {"^TWOII": quote})
                yahoo.assert_not_called()
                quotes.get_quotes(["^TWOII", "^TWII", "^GSPC"])
                self.assertEqual(set(yahoo.call_args.args[0]), {"^TWII", "^GSPC"})
            with patch.object(tpex_index, "get_quote", return_value=None), patch.object(yahoo_quotes, "get_quotes") as yahoo:
                self.assertEqual(quotes.get_quotes(["^TWOII"]), {})
                yahoo.assert_not_called()
        finally:
            quotes.source_preference.reset(token)
        with patch.object(tpex_index, "get_history", return_value=[bar("2026-10-27")]) as history:
            self.assertEqual(stock_info.get_history(" ^twoii ", "1mo", start_date="2026-09-27", end_date="2026-10-27"), [bar("2026-10-27")])
            history.assert_called_once_with("1mo", start_date="2026-09-27", end_date="2026-10-27")

    def test_index_metadata_and_detail_keep_identity_without_company_requests(self):
        quote = quotes.QuoteData("^TWOII", 379.2, 381.69, "TWD", "櫃買指數", as_of="2026-10-27", source="TPEx close")
        with patch.object(indices, "_load_symbols", return_value=["^TWOII"]), \
             patch.object(quotes, "get_quotes", return_value={"^TWOII": quote}), patch.object(indices.live_quotes, "get", return_value=None):
            row = indices.get_indices(db=MagicMock(), user="synthetic")["indices"][0]
        self.assertEqual((row["symbol"], row["market"], row["as_of"], row["source"]),
                         ("^TWOII", "TW", "2026-10-27", "TPEx close"))
        self.assertAlmostEqual(row["change"], -2.49)
        with patch.object(quotes, "get_quote", return_value=quote), \
             patch.object(stock_info, "get_history", return_value=[bar("2026-10-27")]) as history, \
             patch.object(stock_info, "get_fundamentals") as fundamentals, \
             patch.object(stock_info, "get_monthly_revenue") as revenue, \
             patch.object(stock_info, "get_quarterly_financials") as financials:
            db = MagicMock()
            detail = stock.stock_detail("^twoii", period="1mo", db=db, user="synthetic")
        self.assertEqual(detail["symbol"], "^TWOII")
        self.assertEqual(detail["history"], [bar("2026-10-27")])
        self.assertEqual(detail["fundamentals"], {})
        history.assert_called_once_with("^TWOII", "1mo")
        for call in (fundamentals, revenue, financials, db.query):
            call.assert_not_called()
