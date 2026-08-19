repo: jimmy19981226/stock-tracker
branch: main
path: ios/StockTracker

## Last sync
date: 2026-08-19T03:22:45Z
commit: 4e2778d44dda

### Updated in this project
- Synced after the merge — the app now ships the Industry design language (light ground, steel accent, Barlow Condensed numerals, five-tab bar)
- Rebuilt "AI Stock Studio App.dc.html" from the merged source: both palettes resolved per theme, exact radius/space/type ladders, Fmt rules (U+2212 minus, US$, amount vs price digits)
- Screens: Overview (hero + USD stat strip, net-worth chart, market cards), Dashboard (hero, 2×3 stat grid, total-earned chart, Performance with benchmark picker + monthly P&L, holdings with weight bars), Stock detail, Trades (filters + pagination), Dividends (calendar + received), Settings (six groups), Assistant, index bar, About modal
- Second pass: read StockDetail, Onboarding, TradeForm, ImportRecords and the Assistant view structure — every screen is now grounded in source rather than patterned
- Third pass: read TradeRecordView + DividendRecordView and built both record pages (row tap → record → edit/delete); restored the form's source labels and market-dependent placeholder
- Fifth pass: read ai_tools.py to review the assistant's tool surface — gap analysis only, no code changed
- Fourth pass: read income.py and corrected the demo calendar to its real rule — estimates now compute as per-share × shares held, split into TW/US groups with per-currency subtotals
- Previous dark midnight-blue replica deleted; it predates the merge

## Screen map
| Project screen | Repo source |
| --- | --- |
| Theme tokens, both palettes, radius/space/type ladders | ios/StockTracker/Theme/Theme.swift |
| Formatting (minus sign, US$, amount vs price) | ios/StockTracker/Util/Format.swift |
| Shared components (SegmentedControl, StatCell, HeroStat, TickerLine, TagChip, MovePct, SeriesChart, ComparisonChart, BarRow, WeightBar, Paginator, PageBar, Toast) | ios/StockTracker/Views/Components/Components.swift |
| Five-tab shell + drawn tab bar | ios/StockTracker/Views/RootView.swift |
| Overview | ios/StockTracker/Views/Overview/OverviewView.swift |
| Market dashboard | ios/StockTracker/Views/Portfolio/DashboardView.swift |
| Performance card | ios/StockTracker/Views/Portfolio/PerformanceCard.swift |
| Trades list + filters + pagination | ios/StockTracker/Views/Trades/TradesView.swift |
| Dividends + calendar | ios/StockTracker/Views/Dividends/DividendsView.swift |
| Settings + About | ios/StockTracker/Views/Settings/SettingsView.swift |
| Market index bar + editor | ios/StockTracker/Views/Components/IndexBarView.swift |
| Stock detail (price block, chart + markers, position, 52-wk, 9-cell stats, 月營收, 8-quarter financials, records) | ios/StockTracker/Views/StockDetail/StockDetailView.swift |
| Sign-in gate | ios/StockTracker/Views/Onboarding/OnboardingView.swift |
| Add/edit record sheet (explicit market, auto fee, validation) | ios/StockTracker/Views/Trades/TradeFormView.swift |
| AI import (4 steps, per-row include toggles, duplicate flags) | ios/StockTracker/Views/Import/ImportRecordsView.swift |
| Assistant (tool lines, Reasoning block, sources, draft confirm card) | ios/StockTracker/Views/Assistant/AssistantView.swift |
| Chat history sheet | ios/StockTracker/Views/Assistant/ChatHistoryView.swift |
| Dividend calendar rule (per-share × shares held, Yahoo ex-date, per-currency totals) | backend/app/services/income.py, backend/app/routers/dividends.py |
| Assistant tool surface (14 tools, status labels, proposal/confirm action shape) | backend/app/services/ai_tools.py |
| Trade record page (net cost, FIFO explainer, edit/delete) | ios/StockTracker/Views/Trades/TradeRecordView.swift |
| Dividend record page (per-share at today's holding, notes) | ios/StockTracker/Views/Dividends/DividendRecordView.swift |
| Index editor sheet | ios/StockTracker/Views/Components/IndexBarView.swift |

## Sync history
- 2026-08-18T19:41Z — copied the pre-merge dark midnight-blue UI (Theme.swift @7a8b1b386828)
