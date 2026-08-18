repo: jimmy19981226/stock-tracker
branch: main

## Last sync
date: 2026-08-18T04:00:13Z

### Updated in this project
- Read the real frontend (Dashboard.jsx, format.js, marketHours.js) and iOS PerformanceCard / IndexBarView to ground the redesign
- Rebuilt "AI Stock Studio App.dc.html" as a production-quality iOS app: sign-in gate, net-worth history tabs, hero stat strip, market share, holdings weight bars, index bar, Performance (TWR/annualized/vs benchmark + monthly P&L), monthly revenue + quarterly financials, dividend calendar, CSV export, About/privacy
- Live 5 s quote polling while TW is open; US frozen at last close
- Home Screen widget panel removed at the user's request

## Screen map
| Project screen | Repo source |
| --- | --- |
| Sign-in / splash | ios/StockTracker/Views/Onboarding/OnboardingView.swift, Splash/SplashView.swift |
| Overview (net worth, chart tabs, TW/US cards) | ios Views/Overview/OverviewView.swift, frontend/src/components/Dashboard.jsx, /api/portfolio/overview |
| Market dashboard (total earned, summary, holdings) | ios Views/Portfolio/DashboardView.swift, /api/portfolio/summary + holdings |
| Performance card (TWR / XIRR / benchmark / monthly P&L) | ios Views/Portfolio/PerformanceCard.swift, /api/portfolio/performance |
| Market index bar (加權指數 / S&P 500) | ios Views/Components/IndexBarView.swift |
| Stock detail (chart markers, 52-wk, 月營收, financials) | ios Views/StockDetail/StockDetailView.swift, /api/stock/{ticker}/detail |
| Trades list + add/delete | ios Views/Trades/TradesView.swift, TradeFormView.swift, /api/trades |
| Dividends + calendar | ios Views/Dividends/DividendsView.swift, DividendFormView.swift, /api/dividends |
| AI import | ios Views/Import/ImportRecordsView.swift, /api/ai/parse-records |
| Assistant (tools, reasoning, confirm card, history) | ios Views/Assistant/AssistantView.swift, ChatHistoryView.swift, /api/ai/chat |
| Settings (provider, backend, data, markets, about) | ios Views/Settings/SettingsView.swift, AIProviderSettingsView.swift, /api/markets |
| Number/percent formatting | frontend/src/format.js |
| Market open/closed logic | frontend/src/marketHours.js, ios Util/MarketHours.swift |
