"""Local PDF rendering — the fallback when Adobe isn't configured.

The design's whole argument for Adobe Document Generation is that layout lives
in a `.docx` on the server, so a column can move without an App Store release.
This module does not change that: it exists so the endpoints, the chat card,
the viewer and the Settings screen are all usable *before* an Adobe account and
the four templates exist, which is exactly the order the handoff asks for
("`POST /reports` + `GET /reports/{id}` returning a stub PDF (no Adobe) —
unblocks iOS").

It reproduces the page furniture the templates specify — navy cover with six
cover facts, then content pages with an accent kicker, title, subtitle, a
rule-separated table, a totals row with heavy rules, a footnote, and a footer
carrying generated-at, page N of M and the disclaimer — from the same payload
Adobe would receive. What it cannot reproduce is the typographic detail of a
Word template, and it is not meant to.
"""
from __future__ import annotations

import io

from reportlab.lib.colors import Color, HexColor
from reportlab.lib.pagesizes import A4
from pathlib import Path

from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

# The report palette, from Theme.swift's light values — a report is printed on
# white, so it uses the light theme regardless of the app's appearance setting.
NAVY = HexColor("#1E3348")
NAVY_DEEP = HexColor("#16283C")
ACCENT = HexColor("#5980A6")
TEXT = HexColor("#1D1F20")
SECONDARY = HexColor("#6E7A85")
TERTIARY = HexColor("#9AA4AD")
LINE = HexColor("#E1E2E4")
TINT = HexColor("#E7EDF3")

PAGE_W, PAGE_H = A4
MARGIN = 44
BODY_W = PAGE_W - 2 * MARGIN

# Two families, split per run.
#
# The report is set in the app's own Barlow, so a figure reads the same on the
# page as on screen. Barlow has no CJK, and the CID font that does
# (STSong-Light, whose metrics ship with reportlab, so no file to deploy) maps
# Latin punctuation to full-width CJK forms — a "·" separator came out as "▲".
# So each string is split into CJK and non-CJK runs and drawn with the font
# that actually has the glyphs.
FONTS_DIR = Path(__file__).resolve().parent.parent / "reports" / "fonts"

BODY = "Barlow"
BOLD = "Barlow-SemiBold"
DISPLAY = "BarlowCondensed-SemiBold"
CJK = "STSong-Light"

_registered = False


def _fonts() -> None:
    global _registered
    if _registered:
        return
    pdfmetrics.registerFont(TTFont(BODY, str(FONTS_DIR / "Barlow-Regular.ttf")))
    pdfmetrics.registerFont(TTFont(BOLD, str(FONTS_DIR / "Barlow-SemiBold.ttf")))
    pdfmetrics.registerFont(TTFont(DISPLAY, str(FONTS_DIR / "BarlowCondensed-SemiBold.ttf")))
    pdfmetrics.registerFont(UnicodeCIDFont(CJK))
    _registered = True


def _is_cjk(ch: str) -> bool:
    code = ord(ch)
    return (0x2E80 <= code <= 0x9FFF or 0xF900 <= code <= 0xFAFF
            or 0xFF00 <= code <= 0xFFEF or 0x3000 <= code <= 0x303F)


def _runs(text: str) -> list[tuple[str, bool]]:
    """Split into ``(chunk, is_cjk)`` so each is drawn with a font that has it."""
    out: list[tuple[str, bool]] = []
    for ch in text:
        cjk = _is_cjk(ch)
        if out and out[-1][1] == cjk:
            out[-1] = (out[-1][0] + ch, cjk)
        else:
            out.append((ch, cjk))
    return out


def _text_width(text: str, font: str, size: float) -> float:
    return sum(pdfmetrics.stringWidth(chunk, CJK if cjk else font, size)
               for chunk, cjk in _runs(text))


def _draw(c: canvas.Canvas, x: float, y: float, text: str, font: str,
          size: float, align: str = "left") -> None:
    """Draw one string, switching font per run. Right- and centre-alignment
    measure first, because a run-split string can't use reportlab's own
    ``drawRightString``."""
    if not text:
        return
    if align == "right":
        x -= _text_width(text, font, size)
    elif align == "center":
        x -= _text_width(text, font, size) / 2
    for chunk, cjk in _runs(text):
        run_font = CJK if cjk else font
        c.setFont(run_font, size)
        c.drawString(x, y, chunk)
        x += pdfmetrics.stringWidth(chunk, run_font, size)


def _truncate(c: canvas.Canvas, text: str, width: float, font: str, size: float) -> str:
    if _text_width(text, font, size) <= width:
        return text
    ellipsis = "…"
    while text and _text_width(text + ellipsis, font, size) > width:
        text = text[:-1]
    return text + ellipsis


def _wrap(text: str, width: float, font: str, size: float) -> list[str]:
    words, lines, current = text.split(), [], ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if _text_width(candidate, font, size) <= width:
            current = candidate
            continue
        if current:
            lines.append(current)
        current = word
    if current:
        lines.append(current)
    return lines


class _Doc:
    """A page cursor. Content flows; the cover and the furniture do not."""

    def __init__(self, payload: dict):
        _fonts()
        self.payload = payload
        self.buffer = io.BytesIO()
        self.c = canvas.Canvas(self.buffer, pagesize=A4)
        self.c.setTitle(payload.get("title", "Report"))
        # `page` counts pages *started*; `open_page` says whether one is still
        # being drawn into and therefore still owes a footer. Without the
        # second flag the cover's own showPage() and the first content page's
        # both fired, so every report carried a blank page 2 and a page
        # counter that disagreed with the document.
        self.page = 0
        self.open_page = False
        self.total_pages = 0     # filled on the second pass; see render()
        self.y = 0.0

    # -- furniture ---------------------------------------------------------

    def cover(self) -> None:
        c = self.c
        self.page += 1
        self.open_page = True
        c.setFillColor(NAVY)
        c.rect(0, 0, PAGE_W, PAGE_H, stroke=0, fill=1)
        c.setFillColor(HexColor("#9DBCD9"))
        _draw(c, MARGIN, PAGE_H - 90, "AI STOCK STUDIO", BOLD, 10)
        c.setFillColor(HexColor("#FFFFFF"))
        _draw(c, MARGIN, PAGE_H - 140, self.payload["cover"]["title"], DISPLAY, 34)
        c.setFillColor(HexColor("#9DBCD9"))
        _draw(c, MARGIN, PAGE_H - 162, self.payload["cover"]["subtitle"], BODY, 12)

        y = PAGE_H - 250
        for fact in self.payload["cover"]["facts"]:
            c.setFillColor(HexColor("#9DBCD9"))
            _draw(c, MARGIN, y, fact["label"].upper(), BOLD, 8)
            c.setFillColor(HexColor("#FFFFFF"))
            _draw(c, MARGIN, y - 18, str(fact["value"]), DISPLAY, 17)
            y -= 46

        c.setFillColor(HexColor("#9DBCD9"))
        _draw(c, MARGIN, 54, self.payload.get("generated_at", ""), BODY, 8.5)
        _draw(c, PAGE_W - MARGIN, 54, "Not investment advice", BODY, 8.5, "right")
        c.showPage()
        self.open_page = False

    def _footer(self) -> None:
        c = self.c
        c.setStrokeColor(LINE)
        c.setLineWidth(0.5)
        c.line(MARGIN, 58, PAGE_W - MARGIN, 58)
        c.setFillColor(TERTIARY)
        _draw(c, MARGIN, 44, self.payload.get("generated_at", ""), BODY, 7.5)
        _draw(c, PAGE_W / 2, 44, f"Page {self.page} of {self.total_pages or self.page}",
              BODY, 7.5, "center")
        _draw(c, PAGE_W - MARGIN, 44, "Not investment advice", BODY, 7.5, "right")

    def new_page(self) -> None:
        if self.open_page:
            self._footer()
            self.c.showPage()
        self.page += 1
        self.open_page = True
        self.y = PAGE_H - 70

    def room(self, needed: float) -> None:
        if self.y - needed < 80:
            self.new_page()

    # -- blocks ------------------------------------------------------------

    def heading(self, kicker: str, title: str, subtitle: str = "") -> None:
        self.room(90)
        c = self.c
        c.setFillColor(ACCENT)
        _draw(c, MARGIN, self.y, kicker.upper(), BOLD, 8)
        self.y -= 22
        c.setFillColor(TEXT)
        _draw(c, MARGIN, self.y, title, DISPLAY, 20)
        self.y -= 15
        if subtitle:
            c.setFillColor(SECONDARY)
            _draw(c, MARGIN, self.y, subtitle, BODY, 9.5)
            self.y -= 14
        self.y -= 6

    def table(self, section: dict) -> None:
        columns = section.get("columns") or []
        rows = section.get("rows") or []
        if not columns:
            return
        # Proportional widths: the first text column takes the slack, numeric
        # columns get what their header and values actually need.
        widths = self._column_widths(columns, rows, section.get("totals"))

        self._table_header(columns, widths)
        if not rows:
            self.room(24)
            self.c.setFillColor(SECONDARY)
            _draw(self.c, MARGIN, self.y, "Nothing in this period.", BODY, 9.5)
            self.y -= 22
        for row in rows:
            page_before = self.page
            self.room(20)
            if self.page != page_before:       # continued on a fresh page
                self._table_header(columns, widths)
            self._row(columns, widths, row, TEXT, 9.5)
            self.c.setStrokeColor(LINE)
            self.c.setLineWidth(0.4)
            self.c.line(MARGIN, self.y + 4, PAGE_W - MARGIN, self.y + 4)

        totals = section.get("totals")
        if totals:
            self.room(30)
            c = self.c
            c.setStrokeColor(TEXT)
            c.setLineWidth(1.1)
            c.line(MARGIN, self.y + 12, PAGE_W - MARGIN, self.y + 12)
            self.y -= 4
            self._row(columns, widths, totals, TEXT, 10, bold=True)
            c.line(MARGIN, self.y + 6, PAGE_W - MARGIN, self.y + 6)
            self.y -= 8

        footnote = section.get("footnote")
        if footnote:
            self.room(24)
            self.c.setFillColor(SECONDARY)
            _draw(self.c, MARGIN, self.y, footnote, BODY, 8)
            self.y -= 16
        self.y -= 12

    def _column_widths(self, columns, rows, totals=None) -> list[float]:
        needed = []
        for col in columns:
            widest = _text_width(col["label"].upper(), BOLD, 8)
            for row in rows[:120]:
                widest = max(widest, _text_width(str(row.get(col["key"], "")), BODY, 9.5))
            # The totals row is set bold and a half-point larger, so measuring
            # only the body rows left it to truncate — "NT$448,210" came out
            # "NT$448,…", which on a totals line is the one number nobody can
            # afford to have elided.
            if totals:
                widest = max(widest, _text_width(str(totals.get(col["key"], "")), BOLD, 10))
            needed.append(widest + 12)
        total = sum(needed)
        if total <= BODY_W:
            needed[0] += BODY_W - total
            return needed
        scale = BODY_W / total
        return [w * scale for w in needed]

    def _table_header(self, columns, widths) -> None:
        self.room(28)
        c = self.c
        c.setFillColor(SECONDARY)
        x = MARGIN
        for col, width in zip(columns, widths):
            label = col["label"].upper()
            if col.get("align") == "right":
                _draw(c, x + width - 6, self.y, label, BOLD, 8, "right")
            else:
                _draw(c, x, self.y, label, BOLD, 8)
            x += width
        self.y -= 6
        c.setStrokeColor(TEXT)
        c.setLineWidth(0.8)
        c.line(MARGIN, self.y, PAGE_W - MARGIN, self.y)
        self.y -= 16

    def _row(self, columns, widths, row, colour, size, bold: bool = False) -> None:
        c = self.c
        c.setFillColor(colour)
        x = MARGIN
        for col, width in zip(columns, widths):
            value = str(row.get(col["key"], ""))
            if value:
                font = BOLD if bold else BODY
                value = _truncate(c, value, width - 8, font, size)
                if col.get("align") == "right":
                    _draw(c, x + width - 6, self.y, value, font, size, "right")
                else:
                    _draw(c, x, self.y, value, font, size)
            x += width
        self.y -= 18

    def notes(self, section: dict) -> None:
        self.heading("Method", section["title"])
        for paragraph in section.get("paragraphs", []):
            lines = _wrap(paragraph, BODY_W, BODY, 9.5)
            self.room(len(lines) * 13 + 14)
            self.c.setFillColor(TEXT)
            for line in lines:
                _draw(self.c, MARGIN, self.y, line, BODY, 9.5)
                self.y -= 13
            self.y -= 8

    def finish(self) -> bytes:
        if self.open_page:
            self._footer()
            self.c.showPage()
        self.c.save()
        return self.buffer.getvalue()


def _build(payload: dict, total_pages: int) -> tuple[bytes, int]:
    doc = _Doc(payload)
    doc.total_pages = total_pages
    doc.cover()
    doc.new_page()
    for section in payload.get("sections", []):
        if section.get("kind") == "notes":
            doc.notes(section)
        else:
            doc.heading(payload["title"], section["title"], section.get("subtitle", ""))
            doc.table(section)
    return doc.finish(), doc.page


def render(payload: dict) -> bytes:
    """Two passes, because the footer says "page N of M".

    M isn't known until the content has been laid out, and a footer that only
    says "page 3" makes a reader wonder whether pages are missing — which on a
    document someone might file a tax return from is exactly the wrong doubt to
    leave them with. The first pass is discarded.
    """
    _, pages = _build(payload, 0)
    pdf, _ = _build(payload, pages)
    return pdf


def thumbnail(payload: dict) -> bytes | None:
    """No server-side thumbnail.

    The design puts a page-1 image on the chat card and suggests Adobe's PDF
    Services for it. The app renders that from the PDF it already downloads,
    with PDFKit — native, offline, and one fewer service to hold credentials
    for. Kept as a hook so a server-rendered thumbnail can be added without
    touching the router.
    """
    return None
