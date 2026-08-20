# Handoff: PDF reports via Adobe Document Generation

Two entry points, one backend. Design reference: `AI Stock Studio App.dc.html`
(Settings → Reports, and the Assistant report card + viewer).

## 1. Why Adobe and not a hand-rolled PDF

Layout lives in a `.docx` template on the server; the app only sends JSON. Report
layout changes without an app release and without touching Swift. Adobe
Document Generation API renders template + JSON → PDF. Free tier is 500
Document Transactions/month, which is far more than this app needs.

Services used:
- **Document Generation API** — `.docx` template + JSON → PDF (the core)
- **PDF Services API** — page 1 → PNG for the chat card thumbnail; optional merge/password
- **PDFKit (iOS, native)** — the viewer. Do NOT use PDF Embed API on iOS.

## 2. Templates

Four templates, authored in Word with the Adobe Document Generation Tagger add-in.
Store under `backend/app/reports/templates/`:

| id | file | pages |
| --- | --- | --- |
| `dividend_year` | `dividend_year.docx` | ~5 |
| `holdings_snapshot` | `holdings_snapshot.docx` | ~4 |
| `realized_pl` | `realized_pl.docx` | ~5 |
| `period_performance` | `period_performance.docx` | ~3 |

Every template has the same page furniture: a navy cover page with the six
cover facts, then content pages with a small accent kicker, a page title, a
subtitle line, a rule-separated table, a totals row with a heavy top and
bottom rule, a footnote, and a footer with generated-at, page N of M, and
"Not investment advice". Page geometry and type sizes are in the design file's
viewer — treat that as the visual spec for the `.docx`.

### Cover facts (all templates)
Account · Period · Base currency · USD/TWD used · Positions · Investing net worth

### `dividend_year` page content
1. **Taiwan cash dividends** — Date, Ticker, Basis (the `note` string), Gross,
   Premium, Net. Premium is the 2.11% NHI supplementary premium, applied per
   payment above NT$20,000, shown as a negative or an em dash. Totals row: payment
   count, gross total, net total.
2. **US cash dividends** — Date, Ticker, Gross, Withheld 30%, Net USD, Net TWD.
   Net TWD uses the single cover rate, not a per-payment rate.
3. **Estimated forward 12 months** — Ticker, Market, Next ex-date, Per share,
   Shares, Est. annual. Declared per-share rate × 4 × current shares. Must be
   labelled an estimate.
4. **Method & disclosures** — five paragraphs, verbatim from the design file.

## 3. Backend

### `POST /reports`
```json
{
  "template": "dividend_year",
  "period": "ytd",
  "params": { "ticker": "2330" }
}
```
`period`: `ytd` | `year:2025` | `last_12m` | `all`. `params` is template-specific
(`stock_deep_dive` needs a ticker; the others ignore it).

Returns immediately — rendering is async:
```json
{
  "report_id": "rpt_01J9…",
  "status": "pending",
  "template": "dividend_year",
  "title": "Dividend year report",
  "subtitle": "Jan 1 – Aug 18, 2026 · TWD base",
  "cached": false
}
```

### `GET /reports/{report_id}`
```json
{
  "report_id": "rpt_01J9…",
  "status": "ready",
  "pages": 5,
  "bytes": 419840,
  "url": "/reports/rpt_01J9…/file",
  "thumbnail_url": "/reports/rpt_01J9…/thumb.png",
  "generated_at": "2026-08-18T14:32:07+08:00",
  "fx_rate": 29.45
}
```
`status`: `pending` | `ready` | `failed` (+ `error` string when failed).

### `GET /reports/{report_id}/file`
The PDF. `Content-Type: application/pdf`, `Content-Disposition: inline`.

### `GET /reports`
List of the account's recent reports for a future Reports history screen.

### Caching — required
Cache key: `sha256(template + period + params + data_version)` where
`data_version` is the max `updated_at` across the account's trades and dividends.
A repeat request with an unchanged key returns the existing `report_id` with
`"cached": true` and burns no Document Transaction. Keep files 30 days, then evict.

### Adobe credentials
`ADOBE_CLIENT_ID` / `ADOBE_CLIENT_SECRET` in server env only. Never in the app,
never in the client bundle. The app talks only to our own backend.

### Data assembly
Reuse the existing services — do not re-derive:
- holdings and cost basis: `backend/app/services/portfolio.py`
- FIFO realized P/L: the existing FIFO matcher
- dividends and forward estimates: `backend/app/services/income.py`
- FX: capture one rate at assembly time and put it on the cover; every conversion
  in the document uses that rate

## 4. Assistant tool: `generate_report`

Add to the tool set alongside the tools in `ASSISTANT_TOOLS.md`.

```json
{
  "name": "generate_report",
  "description": "Render a multi-page PDF report from the user's records when the answer is too large or too tabular for chat — a full year of dividends, a tax summary, a full holdings listing, or when the user asks for a report, PDF, or export. Do not use for a short answer that fits in a sentence or a small table.",
  "input_schema": {
    "type": "object",
    "properties": {
      "template": { "type": "string", "enum": ["dividend_year", "holdings_snapshot", "realized_pl", "period_performance"] },
      "period": { "type": "string", "enum": ["ytd", "last_12m", "all"], "default": "ytd" },
      "year": { "type": "integer", "description": "Calendar year; overrides period" },
      "ticker": { "type": "string", "description": "Only for single-stock templates" }
    },
    "required": ["template"]
  }
}
```

Tool result (the model must not see the whole document):
```json
{
  "report_id": "rpt_01J9…",
  "status": "pending",
  "template": "dividend_year",
  "title": "Dividend year report",
  "subtitle": "Jan 1 – Aug 18, 2026 · TWD base",
  "row_count": 8,
  "headline": "Taiwan NT$16,443 net across 6 payments; US US$19.53 net across 2."
}
```
`headline` lets the model write one honest sentence next to the card without
inventing figures. The model must not restate the table.

### When the model should call it
- The user asks for a report, a PDF, an export, or a tax summary
- The answer would be more than ~12 rows
- The answer spans more than one year

Otherwise answer in chat as today. Do not attach a report to a one-line answer.

## 5. iOS UI

### Chat report card — `ReportCardView`
A card in the message list, three states:
- **pending** — page-1 thumbnail placeholder pulsing, "Rendering pages from the template…"
- **ready** — thumbnail, kicker "PDF REPORT", title, subtitle, meta line
  "PDF · 5 pages · 410 KB", and a filled accent **Open** button
- **failed** — "Render job failed" in the loss colour and an outlined **Retry**

Poll `GET /reports/{id}` every 1.5 s while pending, giving up after 60 s into
the failed state. Poll on a task that survives leaving the tab — the existing
assistant generation already continues in the background; match that.

### Viewer — `ReportViewerSheet`
Full-screen sheet over a dark grey ground (#23272B). Top bar: close, title,
meta line, share. `PDFView` in the middle. Bottom bar: ‹ / "1 / 5" / ›, with
the chevrons dimmed at the ends. Share uses `UIActivityViewController` on the
downloaded file URL. Cache the file in `Caches/Reports/` keyed by `report_id`
so reopening is offline.

### Settings → Reports
Between "Markets & indices" and "About". A radio list of the four templates
(name, one-line description, page count), a four-option period segmented
control (YTD / 2025 / Last 12M / All), and a full-width primary button that
reads "Export PDF report" and switches to "Rendering with Document
Generation…" and disabled while the job runs. On ready, push the same
`ReportViewerSheet`. Footnote: "Cached per template and period — the same
report is not re-rendered twice."

## 6. Acceptance criteria

- [ ] `POST /reports` returns in under 300 ms; rendering happens off the request
- [ ] A repeat request with unchanged data returns `cached: true` and no new transaction
- [ ] The dividend report's Taiwan net column equals gross minus the 2.11% premium on payments over NT$20,000, and matches the Dividends screen to the dollar
- [ ] US net equals gross × 0.70, and Net TWD uses the cover rate
- [ ] Every page carries generated-at, page N of M, and the disclaimer
- [ ] Forward estimates are labelled an estimate on the page itself
- [ ] Adobe credentials appear only in server env; no key ships in the app
- [ ] The assistant answers short questions in chat and does not attach a report
- [ ] The report card reaches ready or failed — never stays pending forever
- [ ] The viewer works offline for an already-downloaded report
- [ ] Template file changes take effect without an app release

## 7. Suggested order

1. `POST /reports` + `GET /reports/{id}` returning a stub PDF (no Adobe) — unblocks iOS
2. `ReportCardView`, `ReportViewerSheet`, Settings → Reports against the stub
3. `dividend_year.docx` + Adobe wiring; verify numbers against the Dividends screen
4. Thumbnail via PDF Services; caching layer
5. The remaining three templates
6. `generate_report` tool + the model's call/no-call guidance
