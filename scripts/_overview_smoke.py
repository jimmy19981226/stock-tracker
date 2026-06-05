"""Smoke test for the multi-market Overview landing page + portfolio scoping.

Runs against an ISOLATED SQLite backend (seeded with one US holding AAPL, one
TW holding 2330, one US dividend MSFT) — never the prod Neon DB.
"""
from playwright.sync_api import sync_playwright

FRONTEND = "http://127.0.0.1:5210"


def main() -> None:
    with sync_playwright() as p:
        b = p.chromium.launch(headless=True)
        pg = b.new_page(viewport={"width": 1400, "height": 950})
        pg.goto(FRONTEND, wait_until="networkidle")

        # 1) Overview landing: both market cards + a combined net worth.
        pg.wait_for_selector(".overview", timeout=10000)
        pg.wait_for_selector("[data-agent='overview-tw']", timeout=8000)
        pg.wait_for_selector("[data-agent='overview-us']", timeout=8000)
        networth = pg.locator(".networth-amount").first.inner_text()
        us_card = pg.locator("[data-agent='overview-us']").inner_text()
        tw_card = pg.locator("[data-agent='overview-tw']").inner_text()
        print("[ok] overview shown")
        print("     combined net worth:", networth.strip())
        print("     US card has AAPL value:", "$" in us_card)
        print("     TW card has NT$ value:", "NT$" in tw_card)
        pg.screenshot(path="docs/screenshots/_overview_test.png", full_page=True)

        # 2) Enter the US portfolio.
        pg.locator("[data-agent='overview-us']").click()
        pg.wait_for_selector("[data-agent='nav-trades']", timeout=8000)
        badge = pg.locator(".market-badge").inner_text()
        print("[ok] entered US portfolio, badge =", badge.strip())
        # US dashboard should list the AAPL holding.
        pg.wait_for_selector("[data-agent='holding-AAPL']", timeout=8000)
        print("[ok] US dashboard shows AAPL holding")

        # 3) Trades view → market picker should default to US.
        pg.locator("[data-agent='nav-trades']").click()
        pg.wait_for_selector("[data-agent='trade-market']", timeout=8000)
        market_val = pg.eval_on_selector("[data-agent='trade-market']", "el => el.value")
        print("[ok] TradeForm market picker defaults to:", market_val, "(expect US)")

        # 4) Back to overview.
        pg.locator("[data-agent='nav-overview']").click()
        pg.wait_for_selector(".overview", timeout=8000)
        print("[ok] back to overview works")

        ok = (
            "$" in us_card
            and "NT$" in tw_card
            and badge.strip().endswith("US")
            and market_val == "US"
        )
        print("RESULT:", "PASS" if ok else "FAIL")
        b.close()


if __name__ == "__main__":
    main()
