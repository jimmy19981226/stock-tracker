<div align="center">

# AI Stock Studio

**Stock Studio 2.0.13 · Portfolio tracking and AI assistance for Taiwan and US stocks.**

Track Taiwan and US equities through a native iOS app and a responsive web dashboard, with a shared FastAPI backend for portfolio accounting, market data, and agent tools.

[![CI](https://github.com/jimmy19981226/stock-tracker/actions/workflows/ci.yml/badge.svg)](https://github.com/jimmy19981226/stock-tracker/actions/workflows/ci.yml)
![Backend](https://img.shields.io/badge/FastAPI-Python-009688?logo=fastapi&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-SwiftUI-F05138?logo=swift&logoColor=white)
![Web](https://img.shields.io/badge/Web-React-149ECA?logo=react&logoColor=white)

[Product tour](#product-tour) · [AI architecture](#ai-architecture) · [Run locally](#run-locally) · [Tests](#verification) · [Documentation](#documentation)

</div>

## Product tour

<p align="center">
  <img src="docs/screenshots/ios-overview.png" width="30%" alt="Version 2.0.13 portfolio overview with rotating indices and current-year earnings" />
  <img src="docs/screenshots/ios-dividend-entry.png" width="30%" alt="Add dividend form opened from the portfolio shortcut" />
  <img src="docs/screenshots/ios-assistant.png" width="30%" alt="Redesigned assistant welcome page with editable portfolio prompts" />
</p>
<p align="center">
  <img src="docs/screenshots/ios-dark.png" width="30%" alt="Portfolio overview in dark mode" />
  <img src="docs/screenshots/ios-assistant-chat.png" width="30%" alt="Readable assistant tables and editable follow-up actions" />
  <img src="docs/screenshots/ios-stock.png" width="30%" alt="Native stock detail and position view" />
</p>

Screenshots use **synthetic demonstration portfolios**, not a real account. The
current iOS release is **2.0.13 (build 20)**, dated October 27, 2026. Its teal and
neutral design supports light/dark appearances and five persistent destinations:
Overview, Trades, Assistant, Dividends, and Settings.

### What is in this version

- **Unified portfolio card:** total value, today’s move, lifetime figures, and
  current-year earnings in one surface. Add trade and Add dividend sit below it.
- **Current-year earnings:** realized stock P/L and dividends received, separated
  by currency. Sales use their recorded cost basis, including prior-year buys;
  dividends use payment dates. Future-dated records are excluded from YTD totals.
- **Market index strip:** below “Your portfolio,” rotating through configured
  indices every four seconds, with manual advance and an editor. Supported
  choices include TAIEX, Taiwan OTC, S&P 500, Nasdaq, Dow, SOX, and VIX; quote
  availability depends on the market-data provider. Taiwan OTC uses official
  TWSE MIS quotes and TPEx history, with dated closing-price fallback and a
  retry action when charts are unavailable.
- **Assistant conversations:** quieter bubbles, readable Markdown/tables, copy
  confirmation, editable follow-up prompts, real tool progress, elapsed time,
  stop/recovery controls, and motion that respects Reduce Motion.
- **Persistent navigation:** an inset dock with a full selection pill, larger
  icons, and light/dark support. Tabs remain accessible while typing; switching
  tabs preserves the assistant draft and active conversation.
- **Explicit AI connection:** Included AI uses the server-managed key; Personal
  key uses the saved Keychain credential. iOS uses Gemini 3.5 Flash-Lite.

**Team project.** AI Stock Studio was developed collaboratively. This repository presents the shared system, with implementation credit belonging to its contributors.

AI Stock Studio brings holdings, trades, dividends, market data, and AI assistance into one self-hosted application. The engineering focus is keeping financial calculations in application services while allowing a language model to query those services and explain their results.

| Capability | Implementation |
| :--- | :--- |
| **Grounded assistance** | Typed portfolio tools, account-scoped reads, complete filtered totals, and checks on supported numeric answers |
| **Controlled record changes** | The assistant drafts an action; the iOS app requires confirmation before submitting the write |
| **Two-market accounting** | Taiwan/US holdings, TW moving-average / US FIFO cost basis, realized/unrealized P&L, dividends, and currency conversion |
| **Time-aware analysis** | Dated performance windows, benchmark comparisons, and explicit handling of unavailable history |
| **Multiple clients** | SwiftUI app, WidgetKit snapshot, and a read-only React dashboard |
| **Report generation** | Shared calculation services feed local PDF rendering or optional Adobe document templates |

[Explore all features](docs/FEATURES.md) · [See the screenshot gallery](docs/GALLERY.md)

## AI architecture

```mermaid
flowchart TB
    I[SwiftUI app] --> A[FastAPI chat and SSE]
    W[Read-only React dashboard] --> R[Scoped web API]
    A <--> L[LLM provider]
    A --> T[Typed tool dispatcher]
    T --> P[Portfolio and analytics services]
    R --> P
    P --> D[(SQLite or PostgreSQL)]
    P --> M[Market data adapters]
    T --> C[Proposed record change]
    C --> U[User confirmation in iOS]
    U --> V[Validated record API]
    V --> D
```

**Read → calculate → explain.** The assistant can request holdings, filtered records, purchase lots, performance, fundamentals, and reports. The backend performs account arithmetic and returns structured results. This makes the calculation path inspectable independently of model output.

**Propose → review → commit.** Tool-generated writes are proposals. Confirmation cards let the user review additions, corrections, deletions, and imports before ordinary record endpoints persist them.

**Stream → reconnect.** Server-side chat runs stream status and response events to iOS, with persisted chat history and support for background completion. Regression tests exercise the transport, tool execution, data scoping, and calculation paths with synthetic account data.

The iOS client uses `gemini-3.5-flash-lite`; the backend also contains other provider adapters. A Groq/GPT-OSS option is not included in this release. Provider availability, model output, and market feeds remain external dependencies. The tests establish specific application behaviors, not a guarantee that every generated answer is correct.

## Run locally

### Backend

Use **Python 3.11+**. SQLite is the default; a PostgreSQL connection is optional.

```bash
git clone https://github.com/jimmy19981226/stock-tracker.git
cd stock-tracker/backend
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
cp .env.example .env
# Edit .env and set WEB_DASHBOARD_PASSWORD to a password of your choice.
python -m uvicorn app.main:app --reload --port 8011
```

On Windows, activate with `.venv\Scripts\Activate.ps1`. Open the [local API explorer](http://127.0.0.1:8011/docs) or check `GET /api/health`. A fresh local database starts empty. Add your own records through the iOS client or the API explorer.

### Web dashboard

In another terminal, from the repository root:

```bash
cd frontend
npm ci
npm run dev
```

Open **http://localhost:5173** and enter the dashboard password. Vite forwards `/api` requests to `http://127.0.0.1:8011`. The web client reads the account scope configured by `WEB_DASHBOARD_USER_ID`, which defaults to `legacy`.

### iOS and optional AI

Generate the project with XcodeGen, open it in Xcode, and set the app's backend URL to your own instance before entering records. The repository's existing app configuration includes a hosted default URL. See the [iOS setup guide](ios/README.md).

Portfolio tracking can run without an AI provider key. In iOS Settings → AI assistant, choose Included AI for the server-managed Gemini connection, or Personal key to use your own key. Switching to Included AI preserves your saved key but does not send it. Follow the backend environment example to configure server-managed access. Request content used by AI features is sent to the selected provider.

## Verification

```bash
# From backend/, with the development dependencies installed:
DATABASE_URL=sqlite:///:memory: RUN_GEMINI_LIVE_TESTS=0 python -m unittest discover -s tests -v

# From frontend/:
npm ci
npm run build
```

The backend suite covers account isolation, market-specific accounting, year-to-date earnings, tool calls, confirmation proposals, image handling, exact dated returns, credential failures, Unicode passwords, and token expiry/rotation. Ordinary runs skip the explicitly opt-in live Gemini tests. CI runs the backend tests and a clean web build; native iOS tests require Xcode.

Latest local verification for 2.0.13:

| Check | Result |
| :--- | :--- |
| Backend, isolated SQLite | 128 passed; 12 opt-in live tests skipped |
| iOS unit tests | 52 passed |
| iOS UI regression checks | 15 distinct cases across targeted runs: product tours, YTD layout, navigation, form cancellation, chat, index rotation and retry |
| Release build | iPhone release build succeeds; 2.0.13 (20) installed on device |
| Live OTC data | Official quote and rolling one-month chart history verified through the hosted API |

The previous assistant verification passed 22 distinct UI cases. All 12 live
Gemini scenarios passed at least once; three initially hit provider rate limits
and passed a single paced retry. These are separate from the offline suite.
Live checks consume provider quota and use synthetic records. They do not prove
permanent provider availability or eliminate the slow responses observed on the
hosted service. Run native tests using the [preview/test guide](ios/DesignPreview/README.md).

## Code guide

| Start here | What to inspect |
| :--- | :--- |
| [`ai_tools.py`](backend/app/services/ai_tools.py) | Tool schemas, dispatch, and proposed actions |
| [`ai_analytics.py`](backend/app/services/ai_analytics.py) / [`ai_answers.py`](backend/app/services/ai_answers.py) | Filtered analysis and supported numeric answer checks |
| [`ai.py`](backend/app/routers/ai.py) | Chat lifecycle, streaming, and provider integration |
| [`portfolio.py`](backend/app/services/portfolio.py) / [`performance.py`](backend/app/services/performance.py) | Market-specific accounting and dated performance calculations |
| [`backend/tests/`](backend/tests/) | Integration tests with isolated databases and stubbed external services |
| [`ios/`](ios/) / [`frontend/`](frontend/) | Native app and browser dashboard |

## Deployment boundaries

The backend retains a **guest/legacy account** for local and single-user operation. The web dashboard password protects `/api/web/*`; it does not lock every backend endpoint. The first verified Google account can adopt legacy records. Review these behaviors in [development and deployment notes](docs/DEVELOPMENT.md) before exposing a real portfolio on a public server.

Market feeds may be delayed or unavailable, historical coverage varies, and brokerage fee/tax assumptions may differ from your records. AI output and portfolio metrics support personal analysis; verify consequential decisions against authoritative records.

## Documentation

| Guide | Purpose |
| :--- | :--- |
| [Feature reference](docs/FEATURES.md) | Detailed product capabilities |
| [Screenshot gallery](docs/GALLERY.md) | Current iOS tour and web dashboard |
| [Development and deployment](docs/DEVELOPMENT.md) | Configuration, trust boundaries, tests, and contribution workflow |
| [iOS setup](ios/README.md) | XcodeGen, simulator/device setup, and assistant configuration |
| [Web setup](frontend/README.md) | Dashboard authentication and deployment |
| [Windows self-hosting](docs/SELF_HOSTING_WINDOWS.md) | Existing Windows deployment workflow |
| [Taiwan quote relay](docs/TW_QUOTE_RELAY.md) | Optional quote relay configuration |
