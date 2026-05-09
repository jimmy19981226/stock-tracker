"""One-shot helper: insert a realistic AI chat into the local DB so the
README screenshots can show inline citations + the "Searched the web" meta
strip without re-hitting the Gemini API. Idempotent — wipes and re-creates
the demo chat on every run."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from app.database import Chat, ChatMessage, SessionLocal, init_db

DEMO_TITLE = "What's the latest news about TSMC?"

USER_MSG = "What's the latest news about TSMC (2330)?"

ASSISTANT_MSG = """<!--meta:{"queries": ["TSMC latest news", "台積電 2026 月營收", "TSMC Sony image sensor partnership"], "duration_ms": 6657}-->
Here's the latest news regarding TSMC (2330 台積電):

*   **April 2026 Revenue Report:** TSMC announced its April 2026 consolidated revenue was NT$410.73 billion, marking a 17.5% increase year-over-year. However, this was a slight decrease of 1.1% compared to March. For the first four months of 2026, cumulative revenue reached NT$1.54 trillion, a 29.9% year-over-year increase, setting a new record for the period. Analysts attribute this growth to strong global demand for AI chips.[1][2][3]
*   **Strategic Partnership with Sony:** On May 8, 2026, Sony Semiconductor Solutions and TSMC entered into a preliminary agreement for a strategic partnership to develop and manufacture next-generation image sensors. This collaboration aims to leverage Sony's image sensor design expertise and TSMC's advanced process technology, with a planned production line in Kumamoto, Japan.[4][5]
*   **A13 Technology Debut:** TSMC unveiled its A13 process technology at the 2026 North America Technology Symposium on April 23, 2026, targeting AI-server and high-performance computing customers.[5]
*   **First Quarter 2026 Earnings:** TSMC reported an EPS of NT$22.08 for Q1 2026 — a record-high quarterly profit driven by Blackwell-series GPU orders and Apple A19 inventory build-up.[5][6]
*   **Analyst Sentiment:** Analyst consensus remains overwhelmingly positive, with multiple firms raising target prices over the past month on stronger AI demand visibility.[2]

**Sources:**
1. [investing.com](https://www.investing.com/news/stock-market-news/tsmc-april-2026-revenue)
2. [smartkarma.com](https://www.smartkarma.com/insights/tsmc-2026-q2-outlook)
3. [focustaiwan.tw](https://focustaiwan.tw/business/202605080012)
4. [reuters.com](https://www.reuters.com/technology/tsmc-sony-image-sensor-partnership-2026)
5. [tsmc.com](https://pr.tsmc.com/english/news/2026)
6. [morningstar.com](https://www.morningstar.com/stocks/tsm/quote)"""


def main() -> None:
    init_db()
    with SessionLocal() as db:
        existing = db.query(Chat).filter(Chat.title == DEMO_TITLE).all()
        for c in existing:
            db.delete(c)
        db.commit()

        chat = Chat(title=DEMO_TITLE)
        db.add(chat)
        db.flush()
        db.add(ChatMessage(chat_id=chat.id, role="user", content=USER_MSG))
        db.add(ChatMessage(chat_id=chat.id, role="assistant", content=ASSISTANT_MSG))
        db.commit()
        print(f"Seeded demo chat #{chat.id}: {DEMO_TITLE}")


if __name__ == "__main__":
    main()
