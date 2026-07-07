// Thin client for the read-only web dashboard endpoints (/api/web/*).
// Auth is a single shared password → a short-lived bearer token kept in
// localStorage. Everything here is read-only.

const BASE = (import.meta.env.VITE_API_BASE || "").replace(/\/$/, "");
const TOKEN_KEY = "web.dashboard.token";

export const getToken = () => localStorage.getItem(TOKEN_KEY) || "";
export const setToken = (t) => localStorage.setItem(TOKEN_KEY, t);
export const clearToken = () => localStorage.removeItem(TOKEN_KEY);

async function req(path, { method = "GET", body, auth = true } = {}) {
  const headers = {};
  if (body) headers["Content-Type"] = "application/json";
  if (auth) {
    const t = getToken();
    if (t) headers["Authorization"] = `Bearer ${t}`;
  }
  let res;
  try {
    res = await fetch(`${BASE}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError(0, "Can’t reach the server. Check your connection.");
  }
  if (res.status === 401) {
    clearToken();
    throw new ApiError(401, "Session expired — please sign in again.");
  }
  if (!res.ok) {
    let detail = `Request failed (${res.status})`;
    try {
      const j = await res.json();
      if (j && j.detail) detail = j.detail;
    } catch {
      /* keep default */
    }
    throw new ApiError(res.status, detail);
  }
  if (res.status === 204) return null;
  return res.json();
}

export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export const api = {
  config: () => req("/api/web/config", { auth: false }),
  login: (password) => req("/api/web/login", { method: "POST", body: { password }, auth: false }),
  overview: () => req("/api/web/overview"),
  holdings: () => req("/api/web/holdings"),
  summary: () => req("/api/web/summary"),
  earnings: (days = 365) => req(`/api/web/earnings-history?days=${days}`),
  valueHistory: (market, period) =>
    req(`/api/web/value-history?market=${market}&period=${encodeURIComponent(period)}`),
  // /api/markets is public (no auth) — used for the market-open indicator.
  markets: () => req("/api/markets", { auth: false }),
};
