"""Quick iteration screenshot — captures the dashboard for design review.

    python scripts/_shot.py [view]   # view = dashboard|trades (default dashboard)
"""
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright

OUT = Path(__file__).resolve().parent.parent / "docs" / "screenshots"
view = sys.argv[1] if len(sys.argv) > 1 else "dashboard"

with sync_playwright() as p:
    b = p.chromium.launch(headless=True)
    ctx = b.new_context(viewport={"width": 1680, "height": 1050}, device_scale_factor=2)
    page = ctx.new_page()
    page.goto("http://127.0.0.1:5173/", wait_until="networkidle")
    page.add_style_tag(content="header.app-header{position:static !important;top:auto !important;}")
    page.wait_for_timeout(1800)
    if view == "trades":
        page.locator("nav button", has_text="Trades").first.click()
        page.wait_for_timeout(1200)
    page.screenshot(path=str(OUT / f"_preview_{view}.png"), full_page=True)
    # also a tight top crop so detail is legible
    page.screenshot(path=str(OUT / f"_preview_{view}_top.png"),
                    clip={"x": 0, "y": 0, "width": 1680, "height": 620})
    ctx.close(); b.close()
print(f"saved _preview_{view}.png")
