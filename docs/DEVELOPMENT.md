# Development and deployment

## Configuration

Copy `backend/.env.example` to `backend/.env`. The backend loads it before constructing its database engine and routes.

| Variable | Behavior |
| --- | --- |
| `DATABASE_URL` | Optional PostgreSQL URL; omitted means `backend/data/trades.db` (SQLite) |
| `WEB_DASHBOARD_PASSWORD` | Enables the read-only web login; no password means the dashboard is disabled |
| `WEB_DASHBOARD_USER_ID` | Account scope exposed by the dashboard; defaults to `legacy` |
| `GOOGLE_CLIENT_ID` | Expected Google OAuth audience for signed-in requests |
| `GOOGLE_AI_API_KEY` | Optional server-owned Gemini credential |
| `GOOGLE_AI_MODEL` | Optional backend default; client requests may select a supported model |
| `FRONTEND_ORIGINS` | Comma-separated additional CORS origins |
| `QUOTE_RELAY_URL`, `QUOTE_RELAY_SECRET` | Optional Taiwan quote relay |
| `ADOBE_CLIENT_ID`, `ADOBE_CLIENT_SECRET` | Optional Adobe PDF rendering; local rendering is available without them |

The browser also supports `VITE_API_BASE` for a separately hosted API and `VITE_DEV_API` to override the local proxy target. Never put a provider API key or database password in a `VITE_*` variable: browser build variables are public.

## Trust boundaries

This is a self-hosted application with a compatibility guest mode. Understand these boundaries before a public deployment:

- No mobile/API authorization header selects the shared `legacy` bucket. A malformed supplied header returns 401.
- A valid Google ID token selects `google:<sub>`. Verification requires the configured audience.
- The first verified Google user can adopt legacy records. Complete any intended migration in a controlled environment before public access.
- The web password only protects the read-only `/api/web/*` endpoints. It is not a global backend access control.
- Web tokens expire after 12 hours and are invalidated by password rotation.
- The assistant sends selected context, messages, and attached images to its provider. Local database hosting does not make AI processing entirely local.

For a real portfolio, use a trusted network or an authenticated reverse proxy covering the full backend, configure HTTPS, and verify which endpoints are exposed. Do not publish an unauthenticated legacy portfolio or treat CORS as authentication. Review the deployment's actual authorization policy before adding multiple untrusted users.

## Test workflow

```bash
cd backend
python -m pip install -r requirements-dev.txt
python -m unittest discover -s tests -v
```

The suite builds temporary databases with synthetic data. Market feeds and model transports are replaced while account queries, tools, record validation, calculations, and response handling remain real. The `test_gemini_live.py` checks require explicit `RUN_GEMINI_LIVE_TESTS=1` and a provider key; they may incur usage charges and are excluded from ordinary CI.

```bash
cd frontend
npm ci
npm run build
```

iOS tests live in `ios/Tests` and `ios/UITests`. Generate the Xcode project from `ios/project.yml` and run the relevant scheme in Xcode. Linux CI verifies the backend and web client; it does not validate native iOS behavior.

## Changing the code

Keep portfolio arithmetic in the existing service layer. Model prompts and client views should consume calculated results rather than reimplementing financial logic. Add regression cases when changing date boundaries, FIFO lots, currencies, account scopes, or confirmation behavior. Use synthetic fixtures and never commit `.env`, databases, brokerage statements, or API keys.

For a contribution, explain the observed behavior, the resulting behavior, and the tests run. Keep code, setup instructions, and environment examples in the same change when they depend on one another.
