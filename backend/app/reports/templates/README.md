# Report templates

Four Word templates, authored with the Adobe Document Generation Tagger add-in
and dropped in here as `<template_id>.docx`:

| file | id |
| --- | --- |
| `dividend_year.docx` | `dividend_year` |
| `holdings_snapshot.docx` | `holdings_snapshot` |
| `realized_pl.docx` | `realized_pl` |
| `period_performance.docx` | `period_performance` |

They are **not** in the repository: they are authored in Word, and neither the
backend nor the app needs them to run. Until a `.docx` is present here *and*
`ADOBE_CLIENT_ID` / `ADOBE_CLIENT_SECRET` are set in the server environment,
`services/reports.py` renders the same payload locally
(`services/pdf_fallback.py`), so every endpoint, the chat card, the viewer and
Settings → Reports work end to end.

## The JSON a template is tagged against

`services/reports.assemble()` produces exactly this. Tag against these names.

```jsonc
{
  "template": "dividend_year",
  "title":    "Dividend year report",
  "subtitle": "Jan 1 – Aug 20, 2026 · TWD base",
  "generated_at": "2026-08-20T14:32:07+08:00",
  "fx_rate": 29.45,
  "headline": "…",          // one sentence for the assistant, not for the page
  "row_count": 8,
  "cover": {
    "title": "Dividend year report",
    "subtitle": "Jan 1 – Aug 20, 2026 · TWD base",
    "facts": [ { "label": "Account", "value": "…" }, … ]   // always the six
  },
  "sections": [
    {
      "kind": "table",
      "title": "Taiwan cash dividends",
      "subtitle": "Gross, NHI supplementary premium, net received",
      "columns": [ { "key": "date", "label": "Date", "align": "right"? }, … ],
      "rows":    [ { "date": "2026-03-03", "ticker": "2330", … }, … ],
      "totals":  { "date": "6 payments", "gross": "NT$…", "net": "NT$…" },
      "footnote": "…"
    },
    { "kind": "notes", "title": "Method & disclosures", "paragraphs": [ "…" ] }
  ]
}
```

Every money and percentage value arrives **pre-formatted as a string** — U+2212
for a minus, `NT$` / `US$`, TWD without cents and USD with them. That is
deliberate: the formatting rules live in one place, and a template that
re-derives them will eventually print a figure that disagrees with the same
figure on screen.

`rows` is the repeating region. `columns` carries the header labels and their
alignment, for a template that builds its header dynamically rather than
hard-coding it.
