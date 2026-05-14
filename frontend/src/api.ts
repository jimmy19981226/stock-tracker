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
  // null while MIS quotes are temporarily unavailable for every position
  total_value: number | null;
  total_cost: number;
  total_pl: number | null;
  total_pl_pct: number | null;
  today_pl: number | null;
  today_pl_pct: number | null;
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

export interface ParsedTradeRow {
  type: TradeType;
  ticker: string;
  shares: number;
  price: number;
  date: string;
  fee?: number;
  notes?: string;
}

export interface ParsedDividendRow {
  ticker: string;
  amount: number;
  date: string;
  notes?: string;
}

export interface ParsedRecords {
  trades: ParsedTradeRow[];
  dividends: ParsedDividendRow[];
  notes: string;
}

async function parseRecords(file: File): Promise<ParsedRecords> {
  const form = new FormData();
  form.append("file", file);
  const res = await fetch("/api/ai/parse-records", {
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

export interface MobileSession {
  token: string;
  url: string;
  expires_in: number;
  lan_ip: string;
}

export type MobileSessionStatus =
  | "pending"
  | "received"
  | "parsing"
  | "ready"
  | "error";

export interface MobileSessionPoll {
  status: MobileSessionStatus;
  file_name: string | null;
  parsed: ParsedRecords | null;
  error: string | null;
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

export interface AiStreamCallbacks {
  onInit: (chatId: number, title: string) => void;
  onChunk: (delta: string) => void;
  onDone: (content: string, queries: string[], durationMs: number) => void;
  onError: (detail: string) => void;
}

// Consumes the SSE stream from /api/ai/chat. Each chunk delta is emitted via
// onChunk so the UI can append progressively. The terminal `done` event ships
// the canonical content (with inline [N] citation markers + Sources block)
// which the frontend should swap in to replace the streamed text.
async function aiChatStream(
  chatId: number | null,
  message: string,
  signal: AbortSignal,
  callbacks: AiStreamCallbacks,
): Promise<void> {
  let res: Response;
  try {
    res = await fetch("/api/ai/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, message }),
      signal,
    });
  } catch (err) {
    if ((err as DOMException)?.name === "AbortError") return;
    callbacks.onError(err instanceof Error ? err.message : "Network error");
    return;
  }

  if (!res.ok || !res.body) {
    let detail = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body?.detail) detail = body.detail;
    } catch {
      /* ignore */
    }
    callbacks.onError(detail);
    return;
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let idx: number;
      while ((idx = buffer.indexOf("\n\n")) !== -1) {
        const block = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);
        const dataLine = block
          .split("\n")
          .find((l) => l.startsWith("data:"));
        if (!dataLine) continue;
        const json = dataLine.replace(/^data:\s?/, "");
        if (!json) continue;
        let evt: { type: string; [k: string]: unknown };
        try {
          evt = JSON.parse(json);
        } catch {
          continue;
        }
        switch (evt.type) {
          case "init":
            callbacks.onInit(evt.chat_id as number, evt.title as string);
            break;
          case "chunk":
            callbacks.onChunk(evt.delta as string);
            break;
          case "done":
            callbacks.onDone(
              evt.content as string,
              (evt.queries as string[]) || [],
              (evt.duration_ms as number) || 0,
            );
            break;
          case "error":
            callbacks.onError(evt.detail as string);
            break;
        }
      }
    }
  } catch (err) {
    if ((err as DOMException)?.name === "AbortError") return;
    callbacks.onError(err instanceof Error ? err.message : "Stream error");
  } finally {
    try {
      reader.releaseLock();
    } catch {
      /* ignore */
    }
  }
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
  aiChatStream,
  parseRecords,
  createMobileSession: () =>
    request<MobileSession>("/api/mobile/sessions", { method: "POST" }),
  pollMobileSession: (token: string) =>
    request<MobileSessionPoll>(`/api/mobile/sessions/${encodeURIComponent(token)}`),
  closeMobileSession: (token: string) =>
    request<void>(`/api/mobile/sessions/${encodeURIComponent(token)}`, {
      method: "DELETE",
    }),
  getStockDetail: (ticker: string, period: HistoryPeriod = "1y") =>
    request<StockDetail>(
      `/api/stock/${encodeURIComponent(ticker)}/detail?period=${period}`,
    ),
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

export type HistoryPeriod = "1mo" | "3mo" | "6mo" | "1y" | "2y" | "5y" | "max";

export interface StockDetailLive {
  price: number | null;
  previous_close: number | null;
  today_change: number | null;
  today_change_pct: number | null;
  day_open: number | null;
  day_high: number | null;
  day_low: number | null;
  bid: number | null;
  ask: number | null;
  volume: number | null;
}

export interface StockDetailFundamentals {
  symbol?: string;
  long_name?: string | null;
  short_name?: string | null;
  sector?: string | null;
  industry?: string | null;
  market_cap?: number | null;
  currency?: string | null;
  pe?: number | null;
  forward_pe?: number | null;
  eps?: number | null;
  dividend_yield?: number | null;
  dividend_rate?: number | null;
  payout_ratio?: number | null;
  fifty_two_week_high?: number | null;
  fifty_two_week_low?: number | null;
  fifty_day_avg?: number | null;
  two_hundred_day_avg?: number | null;
  beta?: number | null;
  book_value?: number | null;
  price_to_book?: number | null;
  shares_outstanding?: number | null;
  average_volume?: number | null;
  average_volume_10d?: number | null;
  earnings_date?: string | null;
  ex_dividend_date?: string | null;
  last_dividend_date?: string | null;
  target_mean_price?: number | null;
  target_median_price?: number | null;
  target_high_price?: number | null;
  target_low_price?: number | null;
  analyst_count?: number | null;
  recommendation_mean?: number | null;
  recommendation_key?: string | null;
}

export interface StockDetailPosition {
  shares: number;
  avg_cost: number | null;
  cost_basis: number;
  market_value: number | null;
  unrealized_pl: number | null;
  unrealized_pl_pct: number | null;
  realized_pl: number;
  dividends_received: number;
  total_return: number;
  total_return_pct: number;
  first_buy_date: string | null;
  holding_days: number | null;
  trade_count: number;
  fees_paid: number;
}

export interface StockHistoryBar {
  date: string;
  open: number | null;
  high: number | null;
  low: number | null;
  close: number | null;
  volume: number | null;
}

export interface StockTradeMarker {
  date: string;
  type: "buy" | "sell";
  shares: number;
  price: number;
  fee: number;
  notes: string | null;
}

export interface StockDividendMarker {
  date: string;
  amount: number;
  notes: string | null;
}

export interface MonthlyRevenue {
  month: string; // YYYY-MM
  revenue: number;
  yoy_pct: number | null;
}

export interface QuarterlyFinancials {
  quarter: string; // YYYY-MM-DD
  revenue: number | null;
  net_income: number | null;
  gross_profit: number | null;
  operating_income: number | null;
  eps_diluted: number | null;
  gross_margin: number | null;
  operating_margin: number | null;
  net_margin: number | null;
}

export interface StockDetail {
  ticker: string;
  symbol: string;
  name: string;
  live: StockDetailLive;
  fundamentals: StockDetailFundamentals;
  position: StockDetailPosition | null;
  history: StockHistoryBar[];
  taiex_history: StockHistoryBar[];
  trades: StockTradeMarker[];
  dividends: StockDividendMarker[];
  yield_on_cost: number | null;
  monthly_revenue: MonthlyRevenue[];
  quarterly_financials: QuarterlyFinancials[];
}
