"""Capture full-window screenshots for the README demo gallery.

Usage:
    python scripts/take_screenshots.py

Requires the dev stack already running (Vite on :5173, FastAPI on :8000)
and a seeded demo chat (run ``python backend/seed_demo_chat.py`` first).
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "screenshots"
OUT.mkdir(parents=True, exist_ok=True)

# 1920×1080 with 2× DPR → effectively 4K screenshots, sharp on Retina.
VIEWPORT = {"width": 1920, "height": 1080}
DPR = 2


def main() -> None:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(viewport=VIEWPORT, device_scale_factor=DPR)
        page = ctx.new_page()

        page.goto("http://127.0.0.1:5173/", wait_until="networkidle")
        # Let the panel-cascade animations settle.
        page.wait_for_timeout(1200)

        # 1) Full dashboard.
        page.screenshot(path=str(OUT / "dashboard.png"), full_page=True)
        print("[ok]dashboard.png")

        # 2) Stock detail modal — click the 2330 row.
        try:
            row = page.locator("tr.row-clickable").filter(has_text="2330").first
            row.click()
            page.wait_for_selector(".stock-modal", timeout=5000)
            page.wait_for_timeout(2500)  # wait for charts to draw
            page.screenshot(path=str(OUT / "stock-detail.png"), full_page=False)
            print("[ok]stock-detail.png")
            # Close via Escape — most reliable across modal variants.
            page.keyboard.press("Escape")
            page.wait_for_selector(".modal-backdrop", state="detached", timeout=3000)
        except Exception as exc:
            print(f"  skipped stock-detail: {exc}")
            # Force close any lingering modal so subsequent clicks work.
            page.keyboard.press("Escape")
            page.wait_for_timeout(300)

        page.wait_for_timeout(600)

        # 3) Open the AI assistant sidebar.
        page.locator("button.assistant-toggle").click()
        page.wait_for_selector(".assistant-sidebar", timeout=5000)
        page.wait_for_timeout(800)

        # New chat → shows the welcome card with updated copy + suggestions.
        page.locator("button[title='New chat']").click()
        page.wait_for_timeout(600)
        page.screenshot(path=str(OUT / "assistant-welcome.png"), full_page=False)
        print("[ok]assistant-welcome.png")

        # 4) Load the seeded TSMC chat to show citations + meta strip.
        page.locator("button[title='Show all chats']").click()
        page.wait_for_timeout(600)
        # Click the demo chat row.
        page.locator(".assistant-chat-title-btn").filter(
            has_text="latest news about TSMC"
        ).first.click()
        page.wait_for_selector(".citation-chip", timeout=5000)
        page.wait_for_timeout(800)
        page.screenshot(path=str(OUT / "assistant-citations.png"), full_page=False)
        print("[ok]assistant-citations.png")

        # Expand the meta strip to show the search queries.
        try:
            page.locator(".message-meta.expandable").first.click()
            page.wait_for_timeout(400)
            page.screenshot(
                path=str(OUT / "assistant-meta-expanded.png"), full_page=False
            )
            print("[ok]assistant-meta-expanded.png")
        except Exception as exc:
            print(f"  skipped meta-expanded: {exc}")

        # 5) Delete-confirm modal.
        page.locator("button[title='Show all chats']").click()
        page.wait_for_timeout(500)
        page.locator(".assistant-chat-row")\
            .filter(has_text="latest news about TSMC")\
            .locator("button[title='Delete']")\
            .click()
        page.wait_for_selector(".assistant-confirm-modal", timeout=3000)
        page.wait_for_timeout(400)
        page.screenshot(path=str(OUT / "assistant-delete-modal.png"), full_page=False)
        print("[ok]assistant-delete-modal.png")
        # Cancel — don't actually delete the demo chat.
        page.locator(".assistant-confirm-actions .secondary").click()

        ctx.close()
        browser.close()
    print(f"\nAll screenshots saved to {OUT}")


if __name__ == "__main__":
    main()
