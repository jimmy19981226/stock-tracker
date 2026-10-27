"""Synthetic broker reconciliation across holdings, sales, history and tools."""
from datetime import date
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

from app.database import Dividend, Trade
from app.services import ai_tools, portfolio, reports
from test_ai_features import AIFeatureFixture, USER


class FixedDate(date):
    @classmethod
    def today(cls):
        return cls(2026, 10, 6)


def ledger(market="TW", ticker="2330"):
    # Different purchase prices, a partial sale, then a new purchase.
    return [Trade(id=i, user_id=USER, ticker=ticker, market=market, type=side,
                  shares=shares, price=price, fee=fee, trade_date=day)
            for i, (side, shares, price, fee, day) in enumerate([
                ("buy", 10, 100, 2, date(2025, 8, 1)),
                ("buy", 10, 200, 2, date(2026, 7, 1)),
                ("sell", 10, 250, 1, date(2026, 9, 30)),
                ("buy", 10, 300, 3, date(2026, 10, 2)),
            ], 1)]


class AccountingTests(TestCase):
    def test_taiwan_pools_cost_before_sales_and_reaverages_after_purchases(self):
        rows = ledger()
        state = portfolio.compute_states(reversed(rows))["2330"]
        self.assertEqual(state.shares, 20)
        self.assertAlmostEqual(state.cost_basis, 4505)
        self.assertAlmostEqual(state.realized_pl, 997)
        self.assertEqual(portfolio.realized_by_sell(rows), {3: 997})
        self.assertEqual(ai_tools._realized_by_sell(rows), {3: 997})

    def test_us_keeps_fifo_and_total_profit_reconciles_across_methods(self):
        tw = portfolio.compute_states(ledger())["2330"]
        us = portfolio.compute_states(ledger("US", "AAPL"))["AAPL"]
        self.assertEqual(us.shares, tw.shares)
        self.assertAlmostEqual(us.cost_basis, 5005)
        self.assertAlmostEqual(us.realized_pl, 1497)
        self.assertAlmostEqual(tw.realized_pl - tw.cost_basis, us.realized_pl - us.cost_basis)

    def test_full_liquidation_resets_average_before_reentry(self):
        rows = ledger()[:3]
        rows[2].shares = 20
        rows += [Trade(id=4, user_id=USER, ticker="2330", market="TW", type="buy",
                       shares=5, price=70, fee=3, trade_date=date(2026, 10, 2))]
        state = portfolio.compute_states(rows)["2330"]
        self.assertEqual(state.shares, 5)
        self.assertAlmostEqual(state.cost_basis, 353)
        self.assertAlmostEqual(state.realized_pl, 1995)

    def test_fractional_partial_sales_keep_average_and_all_booked_profit(self):
        rows = ledger()
        rows += [Trade(id=5, user_id=USER, ticker="2330", market="TW", type="sell",
                       shares=2.5, price=240, fee=1, trade_date=date(2026, 10, 3))]
        state = portfolio.compute_states(rows)["2330"]
        self.assertEqual(state.shares, 17.5)
        self.assertAlmostEqual(state.cost_basis / state.shares, 225.25)
        self.assertAlmostEqual(state.realized_pl, 1032.875)
        self.assertAlmostEqual(sum(portfolio.realized_by_sell(rows).values()), state.realized_pl)

    def test_market_is_authoritative_with_ticker_inference_only_when_missing(self):
        rows = ledger("US")
        self.assertEqual(portfolio.compute_states(rows)["2330"].cost_basis, 5005)
        for row in rows:
            row.market = None
        self.assertEqual(portfolio.compute_states(rows)["2330"].cost_basis, 4505)

    def test_same_day_sales_follow_trade_id_order(self):
        rows = ledger()[:3]
        for row in rows:
            row.trade_date = date(2026, 9, 30)
        state = portfolio.compute_states(reversed(rows))["2330"]
        self.assertEqual(state.cost_basis, 1502)
        self.assertEqual(state.realized_pl, 997)


class AccountingIntegrationTests(AIFeatureFixture):
    def setUp(self):
        super().setUp()
        self.stack.enter_context(patch.object(portfolio, "date", FixedDate))
        self.stack.enter_context(patch.object(portfolio, "_get_quotes_shared", return_value={
            "2330": SimpleNamespace(price=240, previous_close=240, name="Synthetic TW"),
            "AAPL": SimpleNamespace(price=240, previous_close=240, name="Synthetic US"),
        }))
        with self.sessions() as db:
            for model in (Trade, Dividend):
                db.query(model).filter(model.user_id == USER).delete()
            for market, ticker in [("TW", "2330"), ("US", "AAPL")]:
                for row in ledger(market, ticker):
                    row.id = None
                    db.add(row)
            db.commit()

    def tool(self, name, **args):
        result, action = ai_tools.execute(name, args, USER)
        self.assertIsNone(action)
        self.assertNotIn("error", result)
        return result

    def test_holdings_summary_year_and_history_use_the_same_cost_method(self):
        with self.sessions() as db:
            holdings = portfolio.build_holdings(db, USER)
            tw = next(h for h in holdings if h["market"] == "TW")
            self.assertEqual(tw["cost_basis_method"], "moving_average")
            self.assertEqual((tw["cost_basis"], tw["exit_cost"], tw["unrealized_pl"]), (4505, 20, 275))
            summaries = {s["currency"]: s for s in portfolio.summarize(holdings, db, USER)}
            self.assertEqual((summaries["TWD"]["realized_pl"], summaries["TWD"]["year_earned"]), (997, 997))
            self.assertEqual(summaries["USD"]["realized_pl"], 1497)
            # Exercise both pre-window folding and in-window sales.
            for days in (2, 20):
                realized = portfolio.build_realized_history(db, USER, days)
                earned = portfolio.build_earnings_history(db, USER, days)
                self.assertEqual(realized["TWD"][-1]["value"], 997)
                self.assertEqual(earned["TWD"][-1]["realized"], 997)

    def test_filtered_assistant_answers_use_purchases_outside_the_window(self):
        result = self.tool("get_record_summary", ticker="2330", market="TW",
                           start_date="2026-09-01", end_date="2026-09-30")
        self.assertEqual(result["totals"][0]["realized_pl"], 997)
        trades = self.tool("get_trades", ticker="2330", type="sell")
        self.assertEqual(trades["trades"][0]["realized_pl"], 997)

    def test_simulated_taiwan_sale_uses_pool_not_original_purchase_lots(self):
        result = self.tool("simulate_sale", ticker="2330", shares=10, price=240)
        self.assertEqual(result["cost_basis_method"], "moving_average")
        self.assertEqual(result["lots_consumed"], [])
        self.assertEqual(result["cost_basis_consumed"], 2252.5)
        self.assertEqual(result["realized_pl"], 137.5)
        self.assertEqual(result["shares_remaining_after"], 10)
        self.assertEqual(result["average_cost"], 225.25)
        self.assertIn("error", ai_tools.execute("simulate_sale", {"ticker": "2330", "shares": 21, "price": 240}, USER)[0])

    def test_simulated_us_sale_keeps_fifo_cost_and_purchase_lots(self):
        result = self.tool("simulate_sale", ticker="AAPL", shares=10, price=240)
        self.assertEqual(result["cost_basis_method"], "fifo")
        self.assertEqual(result["cost_basis_consumed"], 2002)
        self.assertEqual(result["realized_pl"], 398)
        self.assertEqual(result["lots_consumed"][0]["shares"], 10)

    def test_report_and_delete_preview_share_accounting_with_dashboard(self):
        with self.sessions() as db:
            sections, _, _ = reports._realized_pl(db, USER, date(2026, 9, 1), date(2026, 10, 6), 32, [], {})
            row = next(r for r in sections[0]["rows"] if r["ticker"] == "2330")
            self.assertEqual(row["realized"], "NT$997")
            buy = db.query(Trade).filter(Trade.user_id == USER, Trade.ticker == "2330", Trade.price == 200).one()
            consequences = ai_tools._delete_consequences(db, buy)
            self.assertTrue(any("997 to 1,497" in line for line in consequences), consequences)
