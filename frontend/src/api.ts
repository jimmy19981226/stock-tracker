export type TradeType = "buy" | "sell";

export type TradeStatus = "open" | "closed";

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
  status: TradeStatus;
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
  name: string;
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

export interface ImportResult {
  mode: "append" | "replace";
  trades: number;
  dividends: number;
  deleted_trades: number;
  deleted_dividends: number;
}

async function uploadPortfolioCsv(
  file: File,
  mode: "append" | "replace" = "append",
): Promise<ImportResult> {
  const form = new FormData();
  form.append("file", file);
  const res = await fetch(`/api/data/import?mode=${mode}`, {
    method: "POST",
    body: form,
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
  getNames: () => request<Record<string, string>>("/api/portfolio/names"),
  lookupQuote: (ticker: string) =>
    request<{
      ticker: string;
      found: boolean;
      symbol?: string;
      name?: string;
      price?: number;
      previous_close?: number | null;
      currency?: string;
    }>(`/api/portfolio/quote/${encodeURIComponent(ticker)}`),
  getSummary: () => request<CurrencySummary[]>("/api/portfolio/summary"),
  getRealizedHistory: (days = 180) =>
    request<HistoryByCurrency>(`/api/portfolio/realized-history?days=${days}`),
  getEarningsHistory: (days = 180) =>
    request<EarningsByCurrency>(`/api/portfolio/earnings-history?days=${days}`),
  getAiStatus: () =>
    request<{ configured: boolean; model: string }>("/api/ai/status"),
  listChats: () => request<ChatSummary[]>("/api/ai/chats"),
  getChat: (id: number) => request<ChatDetail>(`/api/ai/chats/${id}`),
  renameChat: (id: number, title: string) =>
    request<ChatSummary>(`/api/ai/chats/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ title }),
    }),
  deleteChat: (id: number) =>
    request<void>(`/api/ai/chats/${id}`, { method: "DELETE" }),
  aiChat: (chatId: number | null, message: string) =>
    request<ChatReply>("/api/ai/chat", {
      method: "POST",
      body: JSON.stringify({ chat_id: chatId, message }),
    }),
};

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

export interface ChatSummary {
  id: number;
  title: string;
  created_at: string;
  updated_at: string;
  message_count: number;
}

export interface ChatDetail {
  id: number;
  title: string;
  created_at: string;
  updated_at: string;
  messages: ChatMessage[];
}

export interface ChatReply {
  chat_id: number;
  title: string;
  message: ChatMessage;
}
