"""Mutation-free smoke test for agentic mode.

Drives the assistant with a `filter_trades` request (which changes NO data) and
verifies the end-to-end machinery: the planner classifies it as an action, the
floating cursor appears, the agent navigates to Trades, and the React-controlled
filter inputs are actually driven (value reaches the components' state).

Run with the dev server on :5199 and backend on :8011.
"""
from playwright.sync_api import sync_playwright

FRONTEND = "http://127.0.0.1:5199"


def main() -> None:
    with sync_playwright() as p:
        b = p.chromium.launch(headless=True)
        pg = b.new_page(viewport={"width": 1400, "height": 900})
        pg.goto(FRONTEND, wait_until="networkidle")

        pg.locator("button.assistant-toggle").click()
        pg.wait_for_selector(".assistant-sidebar", timeout=8000)

        inp = pg.get_by_placeholder("Ask about your portfolio…")
        inp.wait_for(timeout=8000)
        inp.fill("filter my trades to show only 2330 buys")
        inp.press("Enter")

        # 1) The floating cursor must materialise once the plan starts playing.
        pg.wait_for_selector(".agent-cursor", timeout=30000)
        print("[ok] floating cursor appeared")

        # 2) The executor must navigate to Trades and DRIVE the controlled
        #    filter inputs (this is the native-value-setter path that has to
        #    sync React state).
        pg.wait_for_function(
            """() => {
                const t = document.querySelector('[data-agent="trade-filter-ticker"]');
                const ty = document.querySelector('[data-agent="trade-filter-type"]');
                return t && (t.value || '').toUpperCase().includes('2330')
                       && ty && ty.value === 'buy';
            }""",
            timeout=45000,
        )
        ticker_val = pg.eval_on_selector('[data-agent="trade-filter-ticker"]', "el => el.value")
        type_val = pg.eval_on_selector('[data-agent="trade-filter-type"]', "el => el.value")
        # The spotlight ring should have been mounted at some point too.
        had_spot = pg.evaluate("() => !!document.querySelector('.agent-spotlight') || window.__sawSpot === true")

        print(f"[ok] filter ticker input = {ticker_val!r}")
        print(f"[ok] filter type select = {type_val!r}")
        print(f"[info] spotlight present at check = {had_spot}")

        ok = "2330" in (ticker_val or "").upper() and type_val == "buy"
        print("RESULT:", "PASS" if ok else "FAIL")
        b.close()


if __name__ == "__main__":
    main()
