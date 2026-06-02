"""Capture the README demo-gallery screenshots from the live dev stack.

Usage:
    # 1. backend on :8001 and frontend on :5173 must already be running
    # 2. seed the demo chat so the AI citations shot has content:
    python backend/seed_demo_chat.py
    # 3. capture:
    python scripts/take_screenshots.py

Covers every image referenced by README.md:
    dashboard, unrealized,
    stock-detail-top / stock-detail-chart / stock-detail-financials,
    trades,
    assistant-welcome / assistant-citations / assistant-meta-expanded /
    assistant-delete-modal,
    qr-upload-modal, mobile-upload, import-preview.

Each shot is wrapped in its own try/except so one failure doesn't sink the
rest -- the script prints [ok]/[skip] per image and a summary at the end.
"""
from __future__ import annotations

import json
import urllib.request
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "screenshots"
OUT.mkdir(parents=True, exist_ok=True)

FRONTEND = "http://127.0.0.1:5173"
BACKEND = "http://127.0.0.1:8001"

# 1920x1080 at 2x DPR -> effectively 4K, sharp on Retina.
VIEWPORT = {"width": 1920, "height": 1080}
DPR = 2

ok: list[str] = []
skipped: list[str] = []


def shot(name: str, fn) -> None:
    """Run a capture step, recording success/failure without aborting."""
    try:
        fn()
        ok.append(name)
        print(f"[ok]   {name}.png")
    except Exception as exc:  # noqa: BLE001 - report and continue
        skipped.append(name)
        print(f"[skip] {name}: {exc}")


# A synthetic Taiwan brokerage statement, rendered to PNG and fed through the
# real Gemini import pipeline so the preview card shows genuinely-parsed rows.
STATEMENT_HTML = """
<!doctype html><meta charset="utf-8">
<style>
  body { margin:0; font-family:'Microsoft JhengHei','PingFang TC',sans-serif;
         background:#fff; color:#111; }
  .statement { width:680px; padding:28px 32px; }
  h2 { margin:0 0 2px; font-size:20px; }
  .sub { color:#666; font-size:13px; margin-bottom:18px; }
  table { width:100%; border-collapse:collapse; font-size:14px; }
  th,td { padding:9px 8px; text-align:right; border-bottom:1px solid #e3e3e3; }
  th:first-child, td:first-child,
  th:nth-child(2), td:nth-child(2) { text-align:left; }
  thead th { border-bottom:2px solid #333; color:#333; }
  .buy { color:#c0262d; font-weight:600; }
  .sell { color:#1b8a3a; font-weight:600; }
</style>
<div class="statement">
  <h2>富邦證券 成交回報單</h2>
  <div class="sub">帳號 1234567-8 · 民國 115 年 5 月</div>
  <table>
    <thead><tr>
      <th>成交日</th><th>股票</th><th>買賣別</th>
      <th>股數</th><th>成交價</th><th>手續費</th>
    </tr></thead>
    <tbody>
      <tr><td>115/05/02</td><td>2330 台積電</td>
          <td class="buy">買進</td><td>1,000</td><td>1,085.00</td><td>154</td></tr>
      <tr><td>115/05/06</td><td>2454 聯發科</td>
          <td class="buy">買進</td><td>1,000</td><td>1,420.00</td><td>202</td></tr>
      <tr><td>115/05/14</td><td>2317 鴻海</td>
          <td class="sell">賣出</td><td>2,000</td><td>208.50</td><td>59</td></tr>
      <tr><td>115/05/21</td><td>00919 群益台灣精選高息</td>
          <td class="buy">買進</td><td>3,000</td><td>24.18</td><td>20</td></tr>
    </tbody>
  </table>
</div>
"""


def make_statement_png(ctx) -> str:
    page = ctx.new_page()
    page.set_content(STATEMENT_HTML)
    page.wait_for_timeout(300)
    path = OUT.parent / "_tmp_statement.png"
    page.locator(".statement").screenshot(path=str(path))
    page.close()
    return str(path)


def mint_mobile_token() -> str:
    req = urllib.request.Request(f"{BACKEND}/api/mobile/sessions", method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)["token"]


def capture_dashboard_shots(page: Page) -> None:
    page.goto(f"{FRONTEND}/", wait_until="networkidle")
    page.wait_for_timeout(1500)  # let the panel-cascade settle + charts draw

    shot("dashboard", lambda: page.screenshot(
        path=str(OUT / "dashboard.png"), full_page=True))

    shot("unrealized", lambda: page.locator(".panel")
         .filter(has_text="Unrealized P/L by Position").first
         .screenshot(path=str(OUT / "unrealized.png")))


def capture_stock_detail(page: Page) -> None:
    page.locator("tr.row-clickable").filter(has_text="2330").first.click()
    page.wait_for_selector(".stock-modal", timeout=8000)
    # Block until the real content has replaced the loading skeleton --
    # the "Price history" section only renders once the detail fetch resolves.
    page.locator(".stock-section").filter(
        has_text="Price history").first.wait_for(state="visible", timeout=15000)
    page.wait_for_timeout(2200)  # let charts + financials finish drawing

    modal = page.locator(".stock-modal")

    shot("stock-detail-top",
         lambda: modal.screenshot(path=str(OUT / "stock-detail-top.png")))

    def chart():
        page.locator(".stock-section").filter(has_text="Price history").first \
            .scroll_into_view_if_needed()
        page.wait_for_timeout(900)
        modal.screenshot(path=str(OUT / "stock-detail-chart.png"))
    shot("stock-detail-chart", chart)

    def financials():
        page.locator(".stock-section").filter(
            has_text="Quarterly earnings").first.scroll_into_view_if_needed()
        page.wait_for_timeout(900)
        modal.screenshot(path=str(OUT / "stock-detail-financials.png"))
    shot("stock-detail-financials", financials)

    page.keyboard.press("Escape")
    page.wait_for_selector(".stock-modal", state="detached", timeout=4000)


def capture_trades(page: Page) -> None:
    page.locator("nav button", has_text="Trades").first.click()
    page.wait_for_timeout(1200)
    page.screenshot(path=str(OUT / "trades.png"), full_page=True)
    # back to dashboard for the assistant shots
    page.locator("nav button", has_text="Dashboard").first.click()
    page.wait_for_timeout(800)


def capture_assistant(page: Page) -> None:
    page.locator("button.assistant-toggle").click()
    page.wait_for_selector(".assistant-sidebar", timeout=6000)
    page.wait_for_timeout(800)

    def welcome():
        page.locator("button[title='New chat']").click()
        page.wait_for_timeout(700)
        page.screenshot(path=str(OUT / "assistant-welcome.png"))
    shot("assistant-welcome", welcome)

    def citations():
        page.locator("button[title='Show all chats']").click()
        page.wait_for_timeout(600)
        page.locator(".assistant-chat-title-btn").filter(
            has_text="TSMC").first.click()
        page.wait_for_selector(".citation-chip", timeout=6000)
        page.wait_for_timeout(800)
        page.screenshot(path=str(OUT / "assistant-citations.png"))
    shot("assistant-citations", citations)

    def meta_expanded():
        page.locator(".message-meta.expandable").first.click()
        page.wait_for_timeout(500)
        page.screenshot(path=str(OUT / "assistant-meta-expanded.png"))
    shot("assistant-meta-expanded", meta_expanded)

    def delete_modal():
        page.locator("button[title='Show all chats']").click()
        page.wait_for_timeout(600)
        page.locator(".assistant-chat-row").filter(has_text="TSMC") \
            .locator("button[title='Delete']").first.click()
        page.wait_for_selector(".assistant-confirm-modal", timeout=4000)
        page.wait_for_timeout(400)
        page.screenshot(path=str(OUT / "assistant-delete-modal.png"))
        # cancel -- keep the demo chat
        page.locator(".assistant-confirm-modal").get_by_text(
            "Cancel", exact=True).first.click()
        page.wait_for_timeout(300)
    shot("assistant-delete-modal", delete_modal)


def capture_qr_modal(page: Page) -> None:
    # ensure we're in a chat view (input row + phone button visible)
    page.locator("button[title='New chat']").click()
    page.wait_for_timeout(600)

    def qr():
        page.locator("button.assistant-phone-btn").click()
        page.wait_for_selector(".mobile-modal", timeout=6000)
        page.wait_for_timeout(900)  # QR render
        page.locator(".mobile-modal").screenshot(
            path=str(OUT / "qr-upload-modal.png"))
        page.keyboard.press("Escape")
        page.wait_for_timeout(300)
    shot("qr-upload-modal", qr)


def capture_import_preview(page: Page, statement_png: str) -> None:
    def imp():
        page.locator("button[title='New chat']").click()
        page.wait_for_timeout(700)
        page.locator("input[type=file]").first.set_input_files(statement_png)
        # Gemini vision parse -- can take a while
        page.wait_for_selector(".records-preview", timeout=60000)
        page.wait_for_timeout(800)
        page.locator(".records-preview").scroll_into_view_if_needed()
        page.screenshot(path=str(OUT / "import-preview.png"))
    shot("import-preview", imp)


def capture_mobile_page(browser) -> None:
    def mobile():
        token = mint_mobile_token()
        mctx = browser.new_context(
            viewport={"width": 414, "height": 896}, device_scale_factor=3)
        mpage = mctx.new_page()
        mpage.goto(f"{BACKEND}/m/upload/{token}", wait_until="networkidle")
        mpage.wait_for_timeout(800)
        mpage.screenshot(path=str(OUT / "mobile-upload.png"), full_page=True)
        mctx.close()
    shot("mobile-upload", mobile)


def main() -> None:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(viewport=VIEWPORT, device_scale_factor=DPR)
        page = ctx.new_page()

        statement_png = make_statement_png(ctx)

        capture_dashboard_shots(page)
        try:
            capture_stock_detail(page)
        except Exception as exc:  # noqa: BLE001
            print(f"[skip] stock-detail group: {exc}")
            page.keyboard.press("Escape")
        capture_trades(page)
        capture_assistant(page)
        capture_qr_modal(page)
        capture_import_preview(page, statement_png)

        ctx.close()
        capture_mobile_page(browser)
        browser.close()

    Path(statement_png).unlink(missing_ok=True)
    print(f"\nDone. {len(ok)} captured, {len(skipped)} skipped.")
    if skipped:
        print("  skipped:", ", ".join(skipped))


if __name__ == "__main__":
    main()
