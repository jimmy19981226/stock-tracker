export type TradeType = "buy" | "sell";

export interface Trade {
  id: number;
  type: TradeType;
  ticker: string;
  shares: number;
  price: number;
  trade_date: string;
  fee: number;
  notes: string | null;
  created_at: string;
}

export interface TradeCreate {
  type: TradeType;
  ticker: string;
  shares: number;
  price: number;
  trade_date: string;
  fee: number;
  notes?: string | null;
}

export interface Holding {
  ticker: string;
  currency: string;
  shares: number;
  avg_cost: number;
  current_price: number | null;
  market_value: number | null;
  cost_basis: number;
  unrealized_pl: number | null;
  unrealized_pl_pct: number | null;
  today_change: number | null;
  today_change_pct: number | null;
}

export interface CurrencySummary {
  currency: string;
  total_value: number;
  total_cost: number;
  total_pl: number;
  total_pl_pct: number;
  today_pl: number;
  today_pl_pct: number;
  realized_pl: number;
  dividends: number;
  total_earned: number;
  holdings_count: number;
}

export interface Dividend {
  id: number;
  ticker: string;
  amount: number;
  currency: string;
  pay_date: string;
  notes: string | null;
  created_at: string;
}

export interface DividendCreate {
  ticker: string;
  amount: number;
  pay_date: string;
  notes?: string | null;
}

export interface HistoryPoint {
  date: string;
  value: number;
}

export type HistoryByCurrency = Record<string, HistoryPoint[]>;

export interface EarningsPoint {
  date: string;
  realized: number;
  dividends: number;
  total: number;
}

export type EarningsByCurrency = Record<string, EarningsPoint[]>;

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!res.ok) {
    let detail = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body?.detail) detail = body.detail;
    } catch {
      /* ignore */
    }
    throw new Error(detail);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

async function uploadPortfolioCsv(
  file: File,
): Promise<{ trades: number; dividends: number }> {
  const form = new FormData();
  form.append("file", file);
  const res = await fetch("/api/data/import", { method: "POST", body: form });
  if (!res.ok) {
    let detail = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body?.detail) detail = body.detail;
    } catch {
      /* ignore */
    }
    throw new Error(detail);
  }
  return res.json();
}

export const api = {
  listTrades: () => request<Trade[]>("/api/trades"),
  createTrade: (t: TradeCreate) =>
    request<Trade>("/api/trades", {
      method: "POST",
      body: JSON.stringify(t),
    }),
  updateTrade: (id: number, t: TradeCreate) =>
    request<Trade>(`/api/trades/${id}`, {
      method: "PUT",
      body: JSON.stringify(t),
    }),
  deleteTrade: (id: number) =>
    request<void>(`/api/trades/${id}`, { method: "DELETE" }),
  listDividends: () => request<Dividend[]>("/api/dividends"),
  createDividend: (d: DividendCreate) =>
    request<Dividend>("/api/dividends", {
      method: "POST",
      body: JSON.stringify(d),
    }),
  updateDividend: (id: number, d: DividendCreate) =>
    request<Dividend>(`/api/dividends/${id}`, {
      method: "PUT",
      body: JSON.stringify(d),
    }),
  deleteDividend: (id: number) =>
    request<void>(`/api/dividends/${id}`, { method: "DELETE" }),
  importPortfolioCsv: uploadPortfolioCsv,
  exportPortfolioUrl: "/api/data/export",
  getLastExport: () =>
    request<{ last_export: string | null }>("/api/data/last-export"),
  getHoldings: () => request<Holding[]>("/api/portfolio/holdings"),
  getSummary: () => request<CurrencySummary[]>("/api/portfolio/summary"),
  getHistory: (days = 180) =>
    request<HistoryByCurrency>(`/api/portfolio/history?days=${days}`),
  getRealizedHistory: (days = 180) =>
    request<HistoryByCurrency>(`/api/portfolio/realized-history?days=${days}`),
  getEarningsHistory: (days = 180) =>
    request<EarningsByCurrency>(`/api/portfolio/earnings-history?days=${days}`),
};
