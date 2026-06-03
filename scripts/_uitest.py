"""Drive the app like a user and report inconsistent/broken UI reactions.

Captures console errors/warnings, uncaught page errors, failed network
requests, and per-step success + timing while walking every interactive flow.

    python scripts/_uitest.py
"""
from __future__ import annotations

import time
from pathlib import Path

from playwright.sync_api import sync_playwright

BASE = "http://127.0.0.1:5173/"
OUT = Path(__file__).resolve().parent.parent / "docs" / "screenshots"

console_errs: list[str] = []
console_warns: list[str] = []
page_errs: list[str] = []
failed_reqs: list[str] = []
steps: list[tuple[str, str, float]] = []  # (name, status, ms)


def run():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(viewport={"width": 1680, "height": 1050},
                                  device_scale_factor=1)
        page = ctx.new_page()

        page.on("console", lambda m: (
            console_errs.append(m.text) if m.type == "error"
            else console_warns.append(m.text) if m.type == "warning" else None))
        page.on("pageerror", lambda e: page_errs.append(str(e)))
        page.on("requestfailed", lambda r: failed_reqs.append(
            f"{r.method} {r.url} — {r.failure}"))
        page.on("response", lambda r: failed_reqs.append(
            f"HTTP {r.status} {r.url}") if r.status >= 400 else None)

        def step(name, fn):
            t0 = time.time()
            try:
                fn()
                steps.append((name, "ok", (time.time() - t0) * 1000))
            except Exception as exc:  # noqa: BLE001
                steps.append((name, f"FAIL: {exc}", (time.time() - t0) * 1000))

        # --- load ---
        step("load dashboard", lambda: (
            page.goto(BASE, wait_until="networkidle"),
            page.wait_for_selector(".summary-card.hero", timeout=10000),
            page.wait_for_timeout(1200)))

        # --- nav tabs ---
        for tab in ["Trades", "Dividends", "Dashboard"]:
            step(f"nav -> {tab}", lambda tab=tab: (
                page.locator("nav button", has_text=tab).first.click(),
                page.wait_for_timeout(500)))

        # --- rapid tab switching (race/flicker stress) ---
        def rapid():
            for _ in range(3):
                for tab in ["Trades", "Dividends", "Dashboard"]:
                    page.locator("nav button", has_text=tab).first.click()
                    page.wait_for_timeout(80)
            page.wait_for_selector(".summary-card.hero", timeout=5000)
        step("rapid tab switch x9", rapid)

        # --- stock detail modal ---
        def open_modal():
            page.locator("tr.row-clickable").first.click()
            page.wait_for_selector(".stock-modal", timeout=8000)
            page.locator(".stock-section").filter(has_text="Price history").first \
                .wait_for(state="visible", timeout=15000)
            page.wait_for_timeout(1500)
        step("open stock detail", open_modal)

        def period_tabs():
            for label in ["1M", "3M", "6M", "1Y", "All"]:
                btn = page.locator(".stock-period-tabs button", has_text=label).first
                if btn.count():
                    btn.click()
                    page.wait_for_timeout(350)
        step("switch period tabs", period_tabs)

        def taiex_toggle():
            cb = page.locator(".stock-section input[type=checkbox]").first
            if cb.count():
                cb.click(); page.wait_for_timeout(400)
                cb.click(); page.wait_for_timeout(400)
        step("toggle TAIEX overlay", taiex_toggle)

        step("close modal (Esc)", lambda: (
            page.keyboard.press("Escape"),
            page.wait_for_selector(".stock-modal", state="detached", timeout=4000)))

        # --- reopen + close via X button ---
        def modal_x():
            page.locator("tr.row-clickable").first.click()
            page.wait_for_selector(".stock-modal", timeout=8000)
            page.wait_for_timeout(800)
            page.locator(".stock-modal-header button").last.click()
            page.wait_for_selector(".stock-modal", state="detached", timeout=4000)
        step("close modal (X button)", modal_x)

        # --- assistant ---
        def assistant():
            page.locator("button.assistant-toggle").click()
            page.wait_for_selector(".assistant-sidebar", timeout=6000)
            page.wait_for_timeout(700)
            page.locator("button[title='New chat']").click()
            page.wait_for_timeout(500)
            page.locator("button[title='Show all chats']").click()
            page.wait_for_timeout(500)
            rows = page.locator(".assistant-chat-title-btn")
            if rows.count():
                rows.first.click()
                page.wait_for_timeout(800)
        step("assistant open/new/list/select", assistant)
        step("assistant close", lambda: (
            page.locator(".assistant-header button").last.click(),
            page.wait_for_timeout(500)))

        # --- trades: filter + paginate + inline edit ---
        step("nav -> Trades", lambda: (
            page.locator("nav button", has_text="Trades").first.click(),
            page.wait_for_timeout(700)))

        def filter_type():
            f = page.locator(".filter-bar input").first
            if f.count():
                f.fill("2330"); page.wait_for_timeout(500); f.fill(""); page.wait_for_timeout(400)
        step("trades filter typing", filter_type)

        def paginate():
            btns = page.locator(".pagination button")
            n = btns.count()
            if n > 2:
                # click a numbered page then back
                page.locator(".pagination button", has_text="2").first.click()
                page.wait_for_timeout(400)
                page.locator(".pagination button", has_text="1").first.click()
                page.wait_for_timeout(400)
        step("trades pagination", paginate)

        def inline_edit():
            edit = page.locator("button", has_text="Edit").first
            if edit.count():
                edit.click(); page.wait_for_timeout(500)
                # cancel if a cancel appears
                cancel = page.locator("button", has_text="Cancel").first
                if cancel.count():
                    cancel.click(); page.wait_for_timeout(300)
        step("trades inline edit open/cancel", inline_edit)

        page.screenshot(path=str(OUT / "_uitest_final.png"))
        ctx.close(); browser.close()


run()

print("\n===== UI TEST REPORT =====")
print("\n-- steps --")
for name, status, ms in steps:
    flag = "OK " if status == "ok" else "!! "
    print(f"  {flag}{name:32} {ms:6.0f}ms  {'' if status=='ok' else status}")
print(f"\n-- console errors ({len(console_errs)}) --")
for e in console_errs[:40]:
    print("  ERR ", e[:240])
print(f"\n-- console warnings ({len(console_warns)}) --")
seen = set()
for w in console_warns:
    key = w[:80]
    if key in seen:
        continue
    seen.add(key)
    print("  WARN", w[:240])
print(f"\n-- uncaught page errors ({len(page_errs)}) --")
for e in page_errs[:40]:
    print("  PAGEERR", e[:300])
print(f"\n-- failed/4xx-5xx requests ({len(failed_reqs)}) --")
seen = set()
for r in failed_reqs:
    if r[:120] in seen:
        continue
    seen.add(r[:120])
    print("  ", r[:240])
