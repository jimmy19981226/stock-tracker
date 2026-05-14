"""Generate branded placeholder PNGs for README screenshots that haven't
been captured yet. Run from anywhere — writes into the same directory
this script lives in. Replace each placeholder with a real screenshot
once the feature can be captured live."""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


HERE = Path(__file__).resolve().parent

# Brand palette pulled from the app's index.css (--bg, --accent, --accent-2).
BG_TOP = (19, 24, 37)         # #131825
BG_BOT = (10, 14, 22)         # #0a0e16
BORDER = (99, 132, 255, 90)   # accent at low alpha
ACCENT = (99, 132, 255)       # #6384ff
ACCENT2 = (167, 139, 250)     # #a78bfa
TEXT = (232, 236, 242)        # #e8ecf2
MUTED = (107, 117, 137)       # #6b7589
PILL_BG = (52, 211, 153, 60)  # green tint
PILL_FG = (52, 211, 153)


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int],
                      bot: tuple[int, int, int]) -> Image.Image:
    """Two-stop vertical gradient as a base."""
    w, h = size
    img = Image.new("RGB", size, top)
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(top[0] + (bot[0] - top[0]) * t)
        g = int(top[1] + (bot[1] - top[1]) * t)
        b = int(top[2] + (bot[2] - top[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    """Try common Windows fonts; fall back to PIL default if none load."""
    candidates = [
        # Bold variants first if requested
        *(["seguibl.ttf", "seguisb.ttf", "arialbd.ttf"] if bold else []),
        "segoeui.ttf",
        "arial.ttf",
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
    ]
    for name in candidates:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def make_placeholder(
    out_path: Path,
    *,
    width: int,
    height: int,
    eyebrow: str,
    title: str,
    body: str,
    pill: str | None = None,
) -> None:
    img = vertical_gradient((width, height), BG_TOP, BG_BOT)

    # Soft accent glow in top-left corner so it reads as branded, not blank.
    glow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    for r in range(260, 0, -20):
        alpha = max(0, 50 - r // 8)
        gdraw.ellipse(
            (-r // 2, -r // 2, r, r),
            fill=(99, 132, 255, alpha),
        )
    img.paste(glow, (0, 0), glow)

    # Subtle accent border via a 1px frame inset
    frame = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    fdraw = ImageDraw.Draw(frame)
    fdraw.rounded_rectangle(
        (1, 1, width - 2, height - 2),
        radius=18,
        outline=BORDER,
        width=2,
    )
    img.paste(frame, (0, 0), frame)

    draw = ImageDraw.Draw(img, "RGBA")

    # Center the text block vertically. Layout:
    #   [pill]
    #   eyebrow (small, accent)
    #   title (large, white)
    #   body (medium, muted, wrapped)
    eyebrow_font = load_font(18)
    title_font = load_font(38, bold=True)
    body_font = load_font(18)
    pill_font = load_font(14)

    pad_left = 64
    content_w = width - pad_left * 2

    pieces: list[tuple[str, ImageFont.FreeTypeFont, tuple, int]] = []

    if pill:
        pieces.append(("pill", pill_font, (PILL_FG, PILL_BG), 14))

    pieces.append(("eyebrow", eyebrow_font, ACCENT, 16))
    pieces.append(("title", title_font, TEXT, 22))

    # Wrap body to fit width
    body_lines = wrap_text(body, body_font, content_w, draw)

    # Compute total height of the text block
    line_h_body = body_font.getbbox("Ag")[3] - body_font.getbbox("Ag")[1] + 8
    block_h = 0
    if pill:
        block_h += 32 + 14
    block_h += eyebrow_font.getbbox("Ag")[3] + 16
    block_h += title_font.getbbox("Ag")[3] + 22
    block_h += line_h_body * len(body_lines)

    y = (height - block_h) // 2

    if pill:
        pill_text = pill
        bbox = pill_font.getbbox(pill_text)
        pw = bbox[2] - bbox[0] + 24
        ph = 26
        draw.rounded_rectangle(
            (pad_left, y, pad_left + pw, y + ph),
            radius=ph // 2,
            fill=PILL_BG,
            outline=(PILL_FG[0], PILL_FG[1], PILL_FG[2], 140),
            width=1,
        )
        draw.text(
            (pad_left + 12, y + (ph - (bbox[3] - bbox[1])) // 2 - 2),
            pill_text,
            font=pill_font,
            fill=PILL_FG,
        )
        y += ph + 14

    draw.text((pad_left, y), eyebrow, font=eyebrow_font, fill=ACCENT)
    y += eyebrow_font.getbbox("Ag")[3] + 12

    draw.text((pad_left, y), title, font=title_font, fill=TEXT)
    y += title_font.getbbox("Ag")[3] + 18

    for line in body_lines:
        draw.text((pad_left, y), line, font=body_font, fill=MUTED)
        y += line_h_body

    # Footer: "Placeholder · replace with a real screenshot" along the bottom.
    footer_font = load_font(12)
    footer = "Placeholder — replace with a real screenshot."
    fbbox = footer_font.getbbox(footer)
    draw.text(
        (pad_left, height - (fbbox[3] - fbbox[1]) - 22),
        footer,
        font=footer_font,
        fill=MUTED,
    )

    img.save(out_path, "PNG", optimize=True)
    print(f"wrote {out_path.name}")


def wrap_text(text: str, font, max_width: int, draw) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current: list[str] = []
    for w in words:
        trial = " ".join(current + [w])
        bbox = font.getbbox(trial)
        if bbox[2] - bbox[0] <= max_width:
            current.append(w)
        else:
            if current:
                lines.append(" ".join(current))
            current = [w]
    if current:
        lines.append(" ".join(current))
    return lines


def main() -> None:
    # Sized to roughly match the existing screenshots in this folder.
    make_placeholder(
        HERE / "import-preview.png",
        width=1100,
        height=620,
        pill="Agentic AI",
        eyebrow="IMPORT PREVIEW",
        title="Drop a screenshot, edit, then commit",
        body=(
            "Gemini extracts every trade and dividend into an editable card. "
            "Each row has a checkbox, type pill, and inline-editable shares, "
            "price, date and fee. Duplicates of rows already in your portfolio "
            "show an amber 'Already imported' badge and are unchecked by default."
        ),
    )

    make_placeholder(
        HERE / "qr-upload-modal.png",
        width=1100,
        height=620,
        pill="Cross-device",
        eyebrow="SCAN TO UPLOAD",
        title="QR phone-upload modal",
        body=(
            "Mints a session, displays a QR code pointing at a session URL "
            "on your LAN, polls until the phone uploads. Status badge cycles "
            "Waiting -> Received -> Parsing -> Ready, then auto-closes into "
            "the same review-and-confirm card the paperclip flow uses."
        ),
    )

    make_placeholder(
        HERE / "mobile-upload.png",
        width=1100,
        height=620,
        pill="Phone-served",
        eyebrow="MOBILE UPLOAD PAGE",
        title="Pick a photo or PDF, tap Upload",
        body=(
            "Self-contained HTML + JS served by the backend at /m/upload/{token} — "
            "no framework, no external assets, works on flaky cellular. Tap to "
            "choose a brokerage screenshot or take a fresh one, watch the upload "
            "status, then return to your laptop where the parsed rows are waiting."
        ),
    )


if __name__ == "__main__":
    main()
