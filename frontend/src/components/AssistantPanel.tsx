import {
  cloneElement,
  Fragment,
  isValidElement,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import {
  api,
  type ChatDetail,
  type ChatMessage,
  type ChatSummary,
  type Dividend,
  type Holding,
  type ParsedDividendRow,
  type ParsedRecords,
  type ParsedTradeRow,
  type Trade,
} from "../api";
import { MobileUploadModal } from "./MobileUploadModal";

interface Props {
  onClose: () => void;
  holdings?: Holding[];
  /** Existing trades + dividends — used to flag duplicate parsed rows when
   *  the user re-uploads a screenshot they already imported. */
  trades?: Trade[];
  dividends?: Dividend[];
  /** Called after the user confirms imported trades/dividends so the parent
   *  dashboard can refresh. */
  onPortfolioChanged?: () => void;
}

// Local editable copies of the parsed rows. `include` lets the user uncheck
// rows they don't want; `duplicate` flags rows that match something already
// in the portfolio so we can warn and default them to off.
interface PreviewTradeRow extends ParsedTradeRow {
  id: string;
  include: boolean;
  duplicate: boolean;
  fee: number;
}
interface PreviewDividendRow extends ParsedDividendRow {
  id: string;
  include: boolean;
  duplicate: boolean;
}
interface PreviewState {
  fileName: string;
  trades: PreviewTradeRow[];
  dividends: PreviewDividendRow[];
  notes: string;
}

interface Suggestion {
  icon: string;
  category: string;
  prompt: string;
}

// Pool of suggestion templates grouped by category. {ticker} placeholders
// get filled with one of the user's actual top holdings; templates with
// {ticker2} use a different one for comparisons.
const POOL: Record<string, Suggestion[]> = {
  "Trend analysis": [
    { icon: "📈", category: "Trend analysis", prompt: "How is {ticker}'s monthly revenue trending?" },
    { icon: "📈", category: "Trend analysis", prompt: "Show me {ticker}'s YoY revenue growth pattern over the last year." },
    { icon: "📈", category: "Trend analysis", prompt: "Which of my holdings has the strongest YoY revenue growth?" },
    { icon: "📈", category: "Trend analysis", prompt: "Has {ticker}'s revenue beaten the same month last year recently?" },
  ],
  "Margin deep-dive": [
    { icon: "🔬", category: "Margin deep-dive", prompt: "Is {ticker}'s gross margin improving over the last 4 quarters?" },
    { icon: "🔬", category: "Margin deep-dive", prompt: "Compare {ticker}'s operating margin trend across recent quarters." },
    { icon: "🔬", category: "Margin deep-dive", prompt: "Which holdings have the highest net margin right now?" },
    { icon: "🔬", category: "Margin deep-dive", prompt: "How has {ticker}'s EPS grown quarter over quarter?" },
  ],
  "Valuation check": [
    { icon: "🎯", category: "Valuation check", prompt: "Compare {ticker}'s current price to its 1-year analyst target." },
    { icon: "🎯", category: "Valuation check", prompt: "Which of my holdings has the highest P/E?" },
    { icon: "🎯", category: "Valuation check", prompt: "Are any holdings trading near their 52-week high?" },
    { icon: "🎯", category: "Valuation check", prompt: "Show me {ticker}'s P/E vs its sector peers in my portfolio." },
  ],
  "Performance": [
    { icon: "🏆", category: "Performance", prompt: "Top 3 winners in my portfolio by % return?" },
    { icon: "🏆", category: "Performance", prompt: "Which positions are losing money?" },
    { icon: "🏆", category: "Performance", prompt: "What's been the biggest winner this year by NT$?" },
    { icon: "🏆", category: "Performance", prompt: "Show me realized P/L vs unrealized P/L." },
  ],
  "Dividends": [
    { icon: "💰", category: "Dividends", prompt: "Best dividend month in 2025?" },
    { icon: "💰", category: "Dividends", prompt: "Which holdings have the highest yield on cost?" },
    { icon: "💰", category: "Dividends", prompt: "How much have I received in dividends year-to-date?" },
    { icon: "💰", category: "Dividends", prompt: "When is {ticker}'s next ex-dividend date?" },
  ],
  "Concentration": [
    { icon: "🧭", category: "Concentration", prompt: "What's my biggest position by portfolio weight?" },
    { icon: "🧭", category: "Concentration", prompt: "Show my portfolio breakdown by sector." },
    { icon: "🧭", category: "Concentration", prompt: "Am I overconcentrated in any single ticker?" },
  ],
  "Activity": [
    { icon: "📜", category: "Activity", prompt: "Summarize my trading activity over the last 3 months." },
    { icon: "📜", category: "Activity", prompt: "Which ticker have I traded most this year?" },
    { icon: "📜", category: "Activity", prompt: "Summarize my 2024 performance." },
  ],
  "Latest news": [
    { icon: "📰", category: "Latest news", prompt: "What's the latest news on {ticker}?" },
    { icon: "📰", category: "Latest news", prompt: "Search for recent news affecting my biggest holding." },
    { icon: "📰", category: "Latest news", prompt: "Any earnings announcements coming up for my holdings?" },
    { icon: "📰", category: "Latest news", prompt: "What did {ticker} report in its most recent monthly revenue?" },
  ],
  "Market context": [
    { icon: "🌐", category: "Market context", prompt: "What are analysts saying about {ticker} right now?" },
    { icon: "🌐", category: "Market context", prompt: "How is the TW semiconductor sector doing this month?" },
    { icon: "🌐", category: "Market context", prompt: "What macro events could impact {ticker} this quarter?" },
    { icon: "🌐", category: "Market context", prompt: "Search for {ticker}'s latest filings or announcements." },
  ],
};

function pickSuggestions(
  topTickers: string[],
  count = 4,
  shuffleSeed = 0,
): Suggestion[] {
  // Deterministic-ish shuffle so the React render is stable across re-renders
  // until the seed changes (we change the seed when a new chat is started).
  const rand = mulberry32(shuffleSeed || Date.now());
  const categories = Object.keys(POOL);
  const shuffledCats = [...categories].sort(() => rand() - 0.5);
  const picks: Suggestion[] = [];
  let tickerIdx = 0;
  const fallbackTicker = topTickers[0] ?? "2330";

  for (const cat of shuffledCats) {
    if (picks.length >= count) break;
    const variants = POOL[cat];
    const variant = variants[Math.floor(rand() * variants.length)];
    let prompt = variant.prompt;
    while (prompt.includes("{ticker}") || prompt.includes("{ticker2}")) {
      const next =
        topTickers[tickerIdx % Math.max(topTickers.length, 1)] || fallbackTicker;
      prompt = prompt
        .replace("{ticker}", next)
        .replace("{ticker2}", topTickers[(tickerIdx + 1) % Math.max(topTickers.length, 1)] || fallbackTicker);
      tickerIdx += 1;
    }
    picks.push({ ...variant, prompt });
  }
  return picks;
}

// Tiny seeded PRNG so picks are stable per-seed.
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const LAST_CHAT_KEY = "assistant.lastChatId";

type View = "messages" | "list";

export function AssistantPanel({
  onClose,
  holdings = [],
  trades: existingTrades = [],
  dividends: existingDividends = [],
  onPortfolioChanged,
}: Props) {
  const [configured, setConfigured] = useState<boolean | null>(null);
  const [model, setModel] = useState<string>("");
  const [view, setView] = useState<View>("messages");
  const [chats, setChats] = useState<ChatSummary[]>([]);
  const [activeChatId, setActiveChatId] = useState<number | null>(null);
  const [activeTitle, setActiveTitle] = useState<string>("New chat");
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Bumping this number reshuffles which 4 suggestions render. We do that
  // on mount and every time the user starts a fresh chat.
  const [suggestionSeed, setSuggestionSeed] = useState(() => Math.floor(Math.random() * 1e9));
  const [confirmDelete, setConfirmDelete] = useState<{ id: number; title: string } | null>(null);
  // Image / PDF upload → Gemini parse → preview-and-confirm flow.
  const [parsing, setParsing] = useState(false);
  const [parseError, setParseError] = useState<string | null>(null);
  const [preview, setPreview] = useState<PreviewState | null>(null);
  const [importStatus, setImportStatus] = useState<string | null>(null);

  // Auto-dismiss the import success toast — it's an acknowledgment, not a
  // permanent status, so 5s feels right before fading it out so the welcome
  // / chat area returns to a clean state.
  useEffect(() => {
    if (!importStatus) return;
    const id = window.setTimeout(() => setImportStatus(null), 5000);
    return () => clearTimeout(id);
  }, [importStatus]);

  // QR-code phone-upload flow: opens a modal that mints a session, displays
  // a QR for the LAN URL, polls until the phone has uploaded + parsed.
  const [mobileOpen, setMobileOpen] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  // Lets the user cancel an in-flight chat request via the Stop button.
  const abortRef = useRef<AbortController | null>(null);

  // User's top tickers by market value — used to fill {ticker} placeholders
  // in suggestion templates so prompts reference what they actually own.
  const topTickers = useMemo(() => {
    return [...holdings]
      .filter((h) => h && h.ticker && (h.market_value ?? 0) > 0)
      .sort((a, b) => (b.market_value ?? 0) - (a.market_value ?? 0))
      .slice(0, 4)
      .map((h) => h.ticker);
  }, [holdings]);

  const suggestions = useMemo(
    () => pickSuggestions(topTickers, 3, suggestionSeed),
    [topTickers, suggestionSeed],
  );

  // On mount: check AI status, list chats, restore last active chat (if any).
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const status = await api.getAiStatus();
        if (cancelled) return;
        setConfigured(status.configured);
        setModel(status.model);
        if (!status.configured) return;

        const list = await api.listChats();
        if (cancelled) return;
        setChats(list);

        const lastIdRaw = localStorage.getItem(LAST_CHAT_KEY);
        const lastId = lastIdRaw ? Number(lastIdRaw) : NaN;
        if (Number.isFinite(lastId) && list.some((c) => c.id === lastId)) {
          await loadChat(lastId);
        }
      } catch {
        if (!cancelled) setConfigured(false);
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: 9_999_999, behavior: "smooth" });
  }, [messages, busy]);

  useEffect(() => {
    if (configured && view === "messages") inputRef.current?.focus();
  }, [configured, view, activeChatId]);

  async function loadChat(id: number) {
    try {
      const detail: ChatDetail = await api.getChat(id);
      setActiveChatId(detail.id);
      setActiveTitle(detail.title);
      setMessages(detail.messages);
      setError(null);
      setView("messages");
      localStorage.setItem(LAST_CHAT_KEY, String(detail.id));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load chat");
    }
  }

  function newChat() {
    setActiveChatId(null);
    setActiveTitle("New chat");
    setMessages([]);
    setError(null);
    setView("messages");
    setSuggestionSeed(Math.floor(Math.random() * 1e9));
    localStorage.removeItem(LAST_CHAT_KEY);
  }

  async function refreshChats() {
    try {
      const list = await api.listChats();
      setChats(list);
    } catch {
      /* non-fatal */
    }
  }

  async function send(text: string) {
    const trimmed = text.trim();
    if (!trimmed || busy) return;

    // Optimistic: append user message + an empty assistant placeholder that
    // we'll grow as chunks arrive. Keep a stable ref to the assistant index
    // (it's always the last item we just pushed).
    const baseMessages: ChatMessage[] = [
      ...messages,
      { role: "user", content: trimmed },
      { role: "assistant", content: "" },
    ];
    const assistantIdx = baseMessages.length - 1;
    setMessages(baseMessages);
    setInput("");
    setBusy(true);
    setError(null);

    const controller = new AbortController();
    abortRef.current = controller;

    let streamed = "";
    let finalChatId = activeChatId;

    await api.aiChatStream(activeChatId, trimmed, controller.signal, {
      onInit: (id, title) => {
        finalChatId = id;
        setActiveChatId(id);
        setActiveTitle(title);
        localStorage.setItem(LAST_CHAT_KEY, String(id));
      },
      onChunk: (delta) => {
        streamed += delta;
        // Functional update so we don't capture a stale messages array.
        setMessages((prev) => {
          const next = prev.slice();
          if (next[assistantIdx]?.role === "assistant") {
            next[assistantIdx] = { role: "assistant", content: streamed };
          }
          return next;
        });
      },
      onDone: (content) => {
        setMessages((prev) => {
          const next = prev.slice();
          if (next[assistantIdx]?.role === "assistant") {
            next[assistantIdx] = { role: "assistant", content };
          }
          return next;
        });
      },
      onError: (detail) => {
        setError(detail);
        // Remove the empty/partial assistant placeholder if nothing was streamed.
        setMessages((prev) => {
          if (!streamed) return prev.slice(0, assistantIdx);
          return prev;
        });
      },
    });

    setBusy(false);
    abortRef.current = null;
    refreshChats();

    // If the user aborted, the backend persists whatever it had — pull it back
    // so the chat history reflects what was saved (prevents a desynced UI).
    if (controller.signal.aborted && finalChatId != null) {
      api
        .getChat(finalChatId)
        .then((d) => setMessages(d.messages))
        .catch(() => {
          /* leave streamed state visible */
        });
    }
  }

  function stopGeneration() {
    abortRef.current?.abort();
  }

  async function handleFileSelected(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0];
    // Reset the input so the same file can be re-uploaded later.
    if (fileInputRef.current) fileInputRef.current.value = "";
    if (!f) return;
    setParsing(true);
    setParseError(null);
    setImportStatus(null);
    try {
      const result: ParsedRecords = await api.parseRecords(f);
      openPreviewFromParsed(result, f.name);
    } catch (err) {
      setParseError(err instanceof Error ? err.message : "Parse failed");
    } finally {
      setParsing(false);
    }
  }

  function openPreviewFromParsed(result: ParsedRecords, fileName: string) {
    // Detect duplicates against the live portfolio. Match keys are loose enough
    // to forgive minor LLM transcription noise (fee/notes can vary) but tight
    // enough to catch a re-uploaded screenshot. Duplicates are unchecked by
    // default — user has to deliberately opt them back in.
    const isDupTrade = (r: ParsedTradeRow) => {
      const ticker = (r.ticker || "").toUpperCase().trim();
      const shares = Number(r.shares);
      const price = Number(r.price);
      return existingTrades.some(
        (t) =>
          t.type === r.type &&
          t.ticker === ticker &&
          t.trade_date === r.date &&
          Math.abs(t.shares - shares) < 1e-6 &&
          Math.abs(t.price - price) < 0.01,
      );
    };
    const isDupDividend = (r: ParsedDividendRow) => {
      const ticker = (r.ticker || "").toUpperCase().trim();
      const amount = Number(r.amount);
      return existingDividends.some(
        (d) =>
          d.ticker === ticker &&
          d.pay_date === r.date &&
          Math.abs(d.amount - amount) < 0.01,
      );
    };

    const trades: PreviewTradeRow[] = result.trades.map((r, i) => {
      const dup = isDupTrade(r);
      return {
        ...r,
        id: `t-${i}`,
        include: !dup,
        duplicate: dup,
        ticker: (r.ticker || "").toUpperCase().trim(),
        fee: r.fee ?? 0,
      };
    });
    const dividends: PreviewDividendRow[] = result.dividends.map((r, i) => {
      const dup = isDupDividend(r);
      return {
        ...r,
        id: `d-${i}`,
        include: !dup,
        duplicate: dup,
        ticker: (r.ticker || "").toUpperCase().trim(),
      };
    });
    if (trades.length === 0 && dividends.length === 0) {
      setParseError(
        result.notes ||
          "No trades or dividends were detected in that file. Try a clearer screenshot.",
      );
      return;
    }
    setParseError(null);
    setImportStatus(null);
    setPreview({
      fileName,
      trades,
      dividends,
      notes: result.notes || "",
    });
  }

  async function commitPreview() {
    if (!preview) return;
    const tradesToAdd = preview.trades.filter((r) => r.include);
    const dividendsToAdd = preview.dividends.filter((r) => r.include);
    if (tradesToAdd.length === 0 && dividendsToAdd.length === 0) {
      setParseError("Nothing selected to import.");
      return;
    }
    setParsing(true);
    setParseError(null);
    let createdTrades = 0;
    let createdDividends = 0;
    const failures: string[] = [];

    for (const r of tradesToAdd) {
      try {
        await api.createTrade({
          type: r.type,
          ticker: r.ticker,
          shares: Number(r.shares),
          price: Number(r.price),
          trade_date: r.date,
          fee: Number(r.fee || 0),
          notes: r.notes || null,
        });
        createdTrades += 1;
      } catch (err) {
        failures.push(
          `Trade ${r.ticker} ${r.date}: ${err instanceof Error ? err.message : "failed"}`,
        );
      }
    }
    for (const r of dividendsToAdd) {
      try {
        await api.createDividend({
          ticker: r.ticker,
          amount: Number(r.amount),
          pay_date: r.date,
          notes: r.notes || null,
        });
        createdDividends += 1;
      } catch (err) {
        failures.push(
          `Dividend ${r.ticker} ${r.date}: ${err instanceof Error ? err.message : "failed"}`,
        );
      }
    }

    setParsing(false);
    if (createdTrades > 0 || createdDividends > 0) {
      onPortfolioChanged?.();
      const parts: string[] = [];
      if (createdTrades > 0) parts.push(`${createdTrades} trade${createdTrades === 1 ? "" : "s"}`);
      if (createdDividends > 0) parts.push(`${createdDividends} dividend${createdDividends === 1 ? "" : "s"}`);
      setImportStatus(`Imported ${parts.join(" + ")} from ${preview.fileName}.`);
    }
    if (failures.length > 0) {
      setParseError(`${failures.length} row(s) failed: ${failures[0]}`);
      // Keep the preview open with only failed rows so the user can fix them.
      const failedTradeIds = new Set<string>();
      const failedDivIds = new Set<string>();
      for (const r of tradesToAdd) {
        if (failures.some((f) => f.includes(`Trade ${r.ticker} ${r.date}`))) {
          failedTradeIds.add(r.id);
        }
      }
      for (const r of dividendsToAdd) {
        if (failures.some((f) => f.includes(`Dividend ${r.ticker} ${r.date}`))) {
          failedDivIds.add(r.id);
        }
      }
      setPreview({
        ...preview,
        trades: preview.trades.filter((r) => failedTradeIds.has(r.id)),
        dividends: preview.dividends.filter((r) => failedDivIds.has(r.id)),
      });
    } else {
      setPreview(null);
    }
  }

  function cancelPreview() {
    setPreview(null);
    setParseError(null);
  }

  // Stable callbacks for MobileUploadModal — its polling effect lists these
  // in its dep array, so passing inline arrows would cause the effect to
  // tear down on every re-render and miss the "ready" response from the
  // Gemini call (the in-flight tick bails on `if (stopped) return`).
  const handleMobileParsed = useCallback(
    (records: ParsedRecords, fileName: string) => {
      setMobileOpen(false);
      openPreviewFromParsed(records, fileName);
    },
    [],
  );
  const handleMobileClose = useCallback(() => setMobileOpen(false), []);

  function handleDelete(id: number) {
    const chat = chats.find((c) => c.id === id);
    setConfirmDelete({ id, title: chat?.title ?? "this conversation" });
  }

  async function performDelete() {
    if (!confirmDelete) return;
    const { id } = confirmDelete;
    setConfirmDelete(null);
    try {
      await api.deleteChat(id);
      if (id === activeChatId) newChat();
      await refreshChats();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Delete failed");
    }
  }

  // Escape closes the confirm modal without deleting.
  useEffect(() => {
    if (!confirmDelete) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setConfirmDelete(null);
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [confirmDelete]);

  async function handleRename(id: number, title: string) {
    const trimmed = title.trim();
    if (!trimmed) return;
    try {
      const updated = await api.renameChat(id, trimmed);
      if (id === activeChatId) setActiveTitle(updated.title);
      await refreshChats();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Rename failed");
    }
  }

  return (
    <aside className="assistant-sidebar">
      <header className="assistant-header">
        <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0, flex: 1 }}>
          <button
            type="button"
            className="secondary assistant-icon-btn"
            onClick={() => setView(view === "list" ? "messages" : "list")}
            title={view === "list" ? "Back to chat" : "Show all chats"}
          >
            {view === "list" ? "←" : "☰"}
          </button>
          <div style={{ minWidth: 0 }}>
            <div className="assistant-title" title={activeTitle}>
              <span className="assistant-mark" aria-hidden>
                ✦
              </span>
              <span className="assistant-title-text">
                {view === "list" ? "Chats" : activeTitle}
              </span>
            </div>
            {configured && model && view === "messages" && (
              <div className="muted" style={{ fontSize: 10, marginTop: 3 }}>
                {model}
              </div>
            )}
          </div>
        </div>
        <div style={{ display: "flex", gap: 6, flexShrink: 0 }}>
          <button
            type="button"
            className="secondary assistant-icon-btn"
            onClick={newChat}
            title="New chat"
          >
            +
          </button>
          <button
            type="button"
            className="secondary assistant-close"
            onClick={onClose}
            title="Close sidebar"
          >
            ✕
          </button>
        </div>
      </header>

      {configured === null ? (
        <div className="empty" style={{ flex: 1 }}>Loading…</div>
      ) : !configured ? (
        <SetupHelp />
      ) : view === "list" ? (
        <ChatList
          chats={chats}
          activeId={activeChatId}
          onPick={loadChat}
          onDelete={handleDelete}
          onRename={handleRename}
        />
      ) : (
        <>
          <div ref={scrollRef} className="assistant-messages">
            {messages.length === 0 ? (
              <div className="assistant-welcome">
                <div className="assistant-welcome-mark" aria-hidden>
                  ✦
                </div>
                <div className="assistant-welcome-title">
                  Your portfolio copilot
                </div>
                <div className="assistant-welcome-sub muted">
                  I can <RotatingCapabilities topTickers={topTickers} />
                </div>

                <button
                  type="button"
                  className="assistant-upload-cta"
                  onClick={() => fileInputRef.current?.click()}
                  disabled={parsing}
                >
                  <span className="assistant-upload-cta-icon" aria-hidden>
                    📎
                  </span>
                  <span className="assistant-upload-cta-body">
                    <span className="assistant-upload-cta-title">
                      {parsing ? "Parsing your file…" : "Import trades from a screenshot or PDF"}
                    </span>
                    <span className="assistant-upload-cta-sub">
                      PNG · JPG · PDF · up to 8 MB · preview before saving
                    </span>
                  </span>
                  <span className="assistant-upload-cta-chevron" aria-hidden>›</span>
                </button>

                <div className="assistant-suggestions-label muted">
                  Or ask me anything
                </div>
                <div className="assistant-suggestions">
                  {suggestions.map((s) => (
                    <button
                      key={s.prompt}
                      type="button"
                      className="suggestion-card"
                      onClick={() => send(s.prompt)}
                    >
                      <span className="suggestion-icon" aria-hidden>
                        {s.icon}
                      </span>
                      <span className="suggestion-body">
                        <span className="suggestion-category">{s.category}</span>
                        <span className="suggestion-prompt">{s.prompt}</span>
                      </span>
                    </button>
                  ))}
                </div>
                <button
                  type="button"
                  className="assistant-shuffle"
                  onClick={() => setSuggestionSeed(Math.floor(Math.random() * 1e9))}
                  title="Show different suggestions"
                >
                  ↻ Shuffle
                </button>
              </div>
            ) : (
              messages.map((m, i) => (
                <Bubble
                  key={i}
                  message={m}
                  isStreaming={
                    busy &&
                    i === messages.length - 1 &&
                    m.role === "assistant"
                  }
                />
              ))
            )}
            {/* Render the import success toast inside the scrollable area
                so it lives with the conversation/welcome content rather
                than floating in the gap between messages and the input. */}
            {importStatus && !preview && (
              <div className="assistant-import-toast" role="status">
                ✓ {importStatus}
              </div>
            )}
          </div>

          {error && (
            <div className="error" style={{ fontSize: 12 }}>
              {error}
            </div>
          )}

          {preview && (
            <RecordsPreview
              state={preview}
              busy={parsing}
              error={parseError}
              onChange={setPreview}
              onConfirm={commitPreview}
              onCancel={cancelPreview}
            />
          )}

          {!preview && parseError && (
            <div className="error" style={{ fontSize: 12 }}>
              {parseError}
            </div>
          )}

          <form
            onSubmit={(e) => {
              e.preventDefault();
              send(input);
            }}
            className="assistant-input-row"
          >
            <input
              ref={fileInputRef}
              type="file"
              accept="image/png,image/jpeg,image/webp,image/heic,image/heif,application/pdf"
              onChange={handleFileSelected}
              style={{ display: "none" }}
            />
            <button
              type="button"
              className="secondary assistant-attach-btn"
              onClick={() => fileInputRef.current?.click()}
              disabled={busy || parsing}
              title="Upload a brokerage screenshot or PDF — AI will extract trades and dividends"
              aria-label="Attach file"
            >
              {parsing ? <SpinnerIcon /> : <PaperclipIcon />}
            </button>
            <button
              type="button"
              className="secondary assistant-attach-btn assistant-phone-btn"
              onClick={() => setMobileOpen(true)}
              disabled={busy || parsing || mobileOpen}
              title="Scan a QR code with your phone and upload from there"
              aria-label="Send from phone"
            >
              <PhoneScanIcon />
            </button>
            <input
              ref={inputRef}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              placeholder={
                parsing ? "Parsing your file…" : "Ask about your portfolio…"
              }
              disabled={busy || parsing}
            />
            {busy ? (
              <button
                type="button"
                onClick={stopGeneration}
                className="assistant-stop"
                title="Stop generating"
              >
                <span className="assistant-stop-icon" aria-hidden />
                Stop
              </button>
            ) : (
              <button type="submit" disabled={!input.trim() || parsing}>
                Send
              </button>
            )}
          </form>
        </>
      )}

      {confirmDelete && (
        <div
          className="assistant-confirm-backdrop"
          onClick={() => setConfirmDelete(null)}
          role="dialog"
          aria-modal="true"
        >
          <div
            className="assistant-confirm-modal"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="assistant-confirm-title">Delete conversation?</div>
            <div className="assistant-confirm-message">
              <span className="assistant-confirm-name">
                "{confirmDelete.title}"
              </span>{" "}
              will be permanently removed. This can't be undone.
            </div>
            <div className="assistant-confirm-actions">
              <button
                type="button"
                className="secondary"
                onClick={() => setConfirmDelete(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="assistant-confirm-danger"
                onClick={performDelete}
                autoFocus
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      )}

      {mobileOpen && (
        <MobileUploadModal
          onParsed={handleMobileParsed}
          onClose={handleMobileClose}
        />
      )}
    </aside>
  );
}

interface ChatListProps {
  chats: ChatSummary[];
  activeId: number | null;
  onPick: (id: number) => void;
  onDelete: (id: number) => void;
  onRename: (id: number, title: string) => void;
}

function ChatList({ chats, activeId, onPick, onDelete, onRename }: ChatListProps) {
  const [editingId, setEditingId] = useState<number | null>(null);
  const [draft, setDraft] = useState("");

  if (chats.length === 0) {
    return (
      <div className="empty" style={{ flex: 1, padding: 24 }}>
        No conversations yet. Start one from the messages view.
      </div>
    );
  }

  return (
    <div className="assistant-chat-list">
      {chats.map((c) => {
        const isActive = c.id === activeId;
        const isEditing = c.id === editingId;
        return (
          <div
            key={c.id}
            className={`assistant-chat-row${isActive ? " active" : ""}`}
          >
            {isEditing ? (
              <input
                autoFocus
                className="assistant-chat-rename-input"
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                onBlur={() => {
                  if (draft.trim() && draft !== c.title) {
                    onRename(c.id, draft);
                  }
                  setEditingId(null);
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.currentTarget.blur();
                  } else if (e.key === "Escape") {
                    setEditingId(null);
                  }
                }}
              />
            ) : (
              <button
                type="button"
                className="assistant-chat-title-btn"
                onClick={() => onPick(c.id)}
                title={c.title}
              >
                <div className="assistant-chat-title">{c.title}</div>
                <div className="assistant-chat-meta">
                  {c.message_count} msg · {formatRelative(c.updated_at)}
                </div>
              </button>
            )}
            {!isEditing && (
              <div className="assistant-chat-actions">
                <button
                  type="button"
                  className="secondary assistant-icon-btn"
                  onClick={() => {
                    setEditingId(c.id);
                    setDraft(c.title);
                  }}
                  title="Rename"
                >
                  ✏
                </button>
                <button
                  type="button"
                  className="secondary assistant-icon-btn"
                  onClick={() => onDelete(c.id)}
                  title="Delete"
                >
                  🗑
                </button>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

function formatRelative(iso: string): string {
  const d = new Date(iso);
  const diffMs = Date.now() - d.getTime();
  const min = 60_000;
  const hr = 60 * min;
  const day = 24 * hr;
  if (diffMs < min) return "just now";
  if (diffMs < hr) return `${Math.floor(diffMs / min)}m ago`;
  if (diffMs < day) return `${Math.floor(diffMs / hr)}h ago`;
  if (diffMs < 7 * day) return `${Math.floor(diffMs / day)}d ago`;
  return d.toLocaleDateString();
}

function SetupHelp() {
  return (
    <div style={{ padding: 16, lineHeight: 1.6, fontSize: 13, flex: 1, overflowY: "auto" }}>
      <p>
        The Assistant is gated by a free Google AI API key. Without one,
        the chat is disabled and the rest of the app works as normal.
      </p>
      <p style={{ marginTop: 12, fontWeight: 600, color: "var(--text)" }}>
        Setup (one time, ~30 s):
      </p>
      <ol style={{ paddingLeft: 22, marginTop: 6, color: "var(--text-2)" }}>
        <li>
          Create a key at{" "}
          <a
            href="https://aistudio.google.com/apikey"
            target="_blank"
            rel="noreferrer"
            style={{ color: "var(--accent)" }}
          >
            aistudio.google.com/apikey
          </a>
        </li>
        <li>
          Paste it into <code>backend/.env</code>:
          <pre
            style={{
              background: "var(--bg-2)",
              border: "1px solid var(--border)",
              borderRadius: 8,
              padding: 10,
              marginTop: 8,
              fontSize: 11,
              overflowX: "auto",
            }}
          >{`GOOGLE_AI_API_KEY=AIza...`}</pre>
        </li>
        <li>Restart the backend.</li>
      </ol>
      <p
        className="muted"
        style={{ marginTop: 12, fontSize: 11, lineHeight: 1.6 }}
      >
        Privacy: only when you ask a question, your portfolio JSON is sent
        to Google for inference. MIS quotes still happen locally.
      </p>
    </div>
  );
}

interface Citation {
  title: string;
  uri: string;
  hostname: string;
}

interface MessageMeta {
  queries: string[];
  durationMs?: number;
  interrupted?: boolean;
}

// Pull the leading `<!--meta:{...}-->` JSON header (if present) off the
// content. The backend prepends one to every assistant reply so the UI can
// render a "Searched the web for…" or "Thought for Xs" strip above the body.
function splitMeta(content: string): { meta: MessageMeta | null; rest: string } {
  const m = content.match(/^<!--meta:(\{[\s\S]*?\})-->\n?/);
  if (!m) return { meta: null, rest: content };
  try {
    const raw = JSON.parse(m[1]) as {
      queries?: string[];
      duration_ms?: number;
      interrupted?: boolean;
    };
    return {
      meta: {
        queries: raw.queries || [],
        durationMs: raw.duration_ms,
        interrupted: raw.interrupted,
      },
      rest: content.slice(m[0].length),
    };
  } catch {
    return { meta: null, rest: content };
  }
}

// Parse the trailing "**Sources:**\n1. [title](url)\n..." block the backend
// appends after a grounded response. Returns the body without that block plus
// the parsed citations indexed by source number (1-based, so [0] is unused).
function splitSources(content: string): {
  body: string;
  citations: Citation[];
} {
  const marker = /\n\n\*\*Sources:\*\*\n((?:\d+\.\s*\[[^\]]+\]\([^)]+\)\s*\n?)+)\s*$/;
  const m = content.match(marker);
  if (!m) return { body: content, citations: [] };
  const lines = m[1]
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
  const citations: Citation[] = [];
  for (const line of lines) {
    const lm = line.match(/^\d+\.\s*\[([^\]]+)\]\(([^)]+)\)\s*$/);
    if (!lm) continue;
    const title = lm[1];
    const uri = lm[2];
    citations.push({ title, uri, hostname: prettyHost(title, uri) });
  }
  return { body: content.slice(0, m.index!), citations };
}

function prettyHost(title: string, uri: string): string {
  // Gemini fills `title` with the source domain (e.g. "investing.com"),
  // which is exactly what we want for the chip label.
  if (title && /^[\w.-]+\.[a-z]{2,}$/i.test(title.trim())) {
    return title.trim().replace(/^www\./, "");
  }
  try {
    const u = new URL(uri);
    return u.hostname.replace(/^www\./, "");
  } catch {
    return title || "source";
  }
}

function CitationChip({ n, citation }: { n: number; citation: Citation }) {
  const favicon = `https://www.google.com/s2/favicons?domain=${encodeURIComponent(
    citation.hostname,
  )}&sz=64`;
  return (
    <a
      href={citation.uri}
      target="_blank"
      rel="noopener noreferrer"
      className="citation-chip"
      title={`[${n}] ${citation.hostname}`}
    >
      <img className="citation-chip-favicon" src={favicon} alt="" loading="lazy" />
      <span className="citation-chip-label">{citation.hostname}</span>
    </a>
  );
}

// Walk a ReactMarkdown subtree and replace `[N]` text occurrences with chip
// elements. Skips inside <a>/<code>/<pre> so we don't break links or fenced
// code that happens to contain bracketed numerals.
function injectChips(node: ReactNode, citations: Citation[]): ReactNode {
  if (typeof node === "string") {
    if (!/\[\d+\]/.test(node)) return node;
    const parts = node.split(/(\[\d+\])/g);
    return parts.map((part, idx) => {
      const m = part.match(/^\[(\d+)\]$/);
      if (!m) return <Fragment key={idx}>{part}</Fragment>;
      const n = parseInt(m[1], 10);
      const c = citations[n - 1];
      if (!c) return <Fragment key={idx}>{part}</Fragment>;
      return <CitationChip key={idx} n={n} citation={c} />;
    });
  }
  if (Array.isArray(node)) {
    return node.map((c, i) => (
      <Fragment key={i}>{injectChips(c, citations)}</Fragment>
    ));
  }
  if (isValidElement(node)) {
    const tag = typeof node.type === "string" ? node.type : "";
    if (tag === "a" || tag === "code" || tag === "pre") return node;
    const children = (node.props as { children?: ReactNode }).children;
    return cloneElement(
      node,
      undefined,
      injectChips(children, citations),
    );
  }
  return node;
}

function Bubble({
  message,
  isStreaming = false,
}: {
  message: ChatMessage;
  isStreaming?: boolean;
}) {
  const isUser = message.role === "user";

  const { meta, body, citations } = useMemo(() => {
    if (isUser) {
      return { meta: null, body: message.content, citations: [] };
    }
    const { meta, rest } = splitMeta(message.content);
    const split = splitSources(rest);
    return { meta, body: split.body, citations: split.citations };
  }, [isUser, message.content]);

  const wrapWithChips = (children: ReactNode) =>
    citations.length > 0 ? injectChips(children, citations) : children;

  if (isUser) {
    return (
      <div className="bubble-row bubble-row-user">
        <div className="bubble bubble-user">{message.content}</div>
      </div>
    );
  }

  return (
    <div className="bubble-row bubble-row-assistant">
      {meta && <MessageMetaStrip meta={meta} sourceCount={citations.length} />}
      <div
        className={`assistant-body md-content${isStreaming ? " is-streaming" : ""}`}
      >
        <ReactMarkdown
          remarkPlugins={[remarkGfm]}
          components={{
            a: (props) => (
              <a {...props} target="_blank" rel="noopener noreferrer" />
            ),
            p: ({ children }) => <p>{wrapWithChips(children)}</p>,
            li: ({ children }) => <li>{wrapWithChips(children)}</li>,
            td: ({ children }) => <td>{wrapWithChips(children)}</td>,
            th: ({ children }) => <th>{wrapWithChips(children)}</th>,
            strong: ({ children }) => (
              <strong>{wrapWithChips(children)}</strong>
            ),
            em: ({ children }) => <em>{wrapWithChips(children)}</em>,
          }}
        >
          {body}
        </ReactMarkdown>
        {isStreaming && <AiPulseLogo size="cursor" />}
      </div>
    </div>
  );
}

// Rotating capability tagline shown on the empty-chat welcome screen. Cycles
// through what the assistant can actually do, with a subtle fade between
// lines so the user discovers features without us listing all eight at once.
// Personalised: lines that take a ticker fill in the user's biggest holding.
const ROTATING_CAPS: ReadonlyArray<(t: string) => string> = [
  () => "extract trades and dividends from a brokerage screenshot.",
  () => "import records straight from your phone with a QR scan.",
  (t) => `analyze ${t}'s monthly revenue trend and margins.`,
  (t) => `search the web for the latest news on ${t}.`,
  (t) => `compare ${t}'s price to its 1-year analyst target.`,
  () => "tell you which holdings are winning and which are losing.",
  () => "show your dividend history and yield-on-cost.",
  () => "flag if you're overconcentrated in any one ticker.",
];

function RotatingCapabilities({ topTickers }: { topTickers: string[] }) {
  const focus = topTickers[0] || "2330";
  const lines = useMemo(
    () => ROTATING_CAPS.map((fn) => fn(focus)),
    [focus],
  );
  const [i, setI] = useState(0);
  useEffect(() => {
    const id = window.setInterval(
      () => setI((n) => (n + 1) % lines.length),
      3500,
    );
    return () => clearInterval(id);
  }, [lines.length]);
  return (
    <span className="rot-cap-wrap">
      {/* keyed so React re-mounts the inner span on each tick — that's
          what re-fires the CSS fade-in animation. */}
      <span key={i} className="rot-cap">
        {lines[i]}
      </span>
    </span>
  );
}

// Fancy AI logo for in-flight states. The ✦ glyph itself pulses + rotates
// with a brand gradient text-fill, layered with a halo that breathes and a
// sonar ring that radiates outward. Two sizes: "thinking" (placeholder while
// waiting for the first chunk) and "cursor" (smaller, trails streamed text).
function AiPulseLogo({ size = "thinking" }: { size?: "thinking" | "cursor" }) {
  return (
    <span className={`ai-pulse-logo ai-pulse-logo-${size}`} aria-hidden>
      <span className="ai-pulse-logo-glyph">✦</span>
    </span>
  );
}

// Tiny labelled field wrapper used inside each parsed-record card. Keeps
// the column markup compact and makes the field purpose obvious without
// relying on placeholder text (which disappears once the input has a value).
function RecField({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="rec-field">
      <span className="rec-field-label">{label}</span>
      {children}
    </label>
  );
}

interface RecordsPreviewProps {
  state: PreviewState;
  busy: boolean;
  error: string | null;
  onChange: (next: PreviewState) => void;
  onConfirm: () => void;
  onCancel: () => void;
}

function RecordsPreview({
  state,
  busy,
  error,
  onChange,
  onConfirm,
  onCancel,
}: RecordsPreviewProps) {
  const includedTrades = state.trades.filter((r) => r.include).length;
  const includedDivs = state.dividends.filter((r) => r.include).length;
  const totalSelected = includedTrades + includedDivs;
  const duplicateCount =
    state.trades.filter((r) => r.duplicate).length +
    state.dividends.filter((r) => r.duplicate).length;

  function updateTrade(id: string, patch: Partial<PreviewTradeRow>) {
    onChange({
      ...state,
      trades: state.trades.map((r) => (r.id === id ? { ...r, ...patch } : r)),
    });
  }
  function updateDividend(id: string, patch: Partial<PreviewDividendRow>) {
    onChange({
      ...state,
      dividends: state.dividends.map((r) =>
        r.id === id ? { ...r, ...patch } : r,
      ),
    });
  }
  function removeTrade(id: string) {
    onChange({ ...state, trades: state.trades.filter((r) => r.id !== id) });
  }
  function removeDividend(id: string) {
    onChange({ ...state, dividends: state.dividends.filter((r) => r.id !== id) });
  }

  return (
    <div className="records-preview" role="region" aria-label="Parsed records preview">
      <div className="records-preview-header">
        <div>
          <div className="records-preview-title">
            ✦ Found {state.trades.length} trade{state.trades.length === 1 ? "" : "s"}
            {" + "}
            {state.dividends.length} dividend
            {state.dividends.length === 1 ? "" : "s"}
          </div>
          <div className="records-preview-sub muted">
            from {state.fileName} — review, edit, then confirm
            {duplicateCount > 0 && (
              <>
                {" · "}
                <span className="records-preview-dup-note">
                  ⚠ {duplicateCount} already in your portfolio (unchecked)
                </span>
              </>
            )}
          </div>
        </div>
        <button
          type="button"
          className="secondary assistant-icon-btn"
          onClick={onCancel}
          disabled={busy}
          title="Discard"
          aria-label="Discard"
        >
          ✕
        </button>
      </div>

      {state.notes && (
        <div className="records-preview-notes muted">{state.notes}</div>
      )}

      {state.trades.length > 0 && (
        <div className="records-preview-section">
          <div className="records-preview-section-title">
            Trades
            <span className="records-section-count">{state.trades.length}</span>
          </div>
          <div className="records-preview-rows">
            {state.trades.map((r) => (
              <div
                key={r.id}
                className={`rec-card${r.include ? "" : " excluded"}${r.duplicate ? " duplicate" : ""}`}
              >
                <div className="rec-card-head">
                  <input
                    type="checkbox"
                    className="rec-check"
                    checked={r.include}
                    onChange={(e) =>
                      updateTrade(r.id, { include: e.target.checked })
                    }
                    disabled={busy}
                    aria-label="Include this trade"
                  />
                  <select
                    value={r.type}
                    onChange={(e) =>
                      updateTrade(r.id, { type: e.target.value as "buy" | "sell" })
                    }
                    disabled={busy}
                    className={`records-pill records-pill-${r.type}`}
                    aria-label="Trade type"
                  >
                    <option value="buy">Buy</option>
                    <option value="sell">Sell</option>
                  </select>
                  <input
                    className="rec-ticker"
                    value={r.ticker}
                    onChange={(e) =>
                      updateTrade(r.id, { ticker: e.target.value.toUpperCase() })
                    }
                    disabled={busy}
                    placeholder="Ticker"
                    aria-label="Ticker"
                  />
                  {r.duplicate && (
                    <span
                      className="rec-dup-badge"
                      title="A matching trade already exists in your portfolio"
                    >
                      Already imported
                    </span>
                  )}
                  <button
                    type="button"
                    className="rec-remove"
                    onClick={() => removeTrade(r.id)}
                    disabled={busy}
                    title="Remove this row"
                    aria-label="Remove row"
                  >
                    ×
                  </button>
                </div>
                <div className="rec-card-grid rec-card-grid-trade">
                  <RecField label="Shares">
                    <input
                      className="rec-input"
                      type="number"
                      value={r.shares}
                      onChange={(e) =>
                        updateTrade(r.id, {
                          shares: parseFloat(e.target.value) || 0,
                        })
                      }
                      disabled={busy}
                      min={0}
                      aria-label="Shares"
                    />
                  </RecField>
                  <RecField label="Price (NT$)">
                    <input
                      className="rec-input"
                      type="number"
                      value={r.price}
                      onChange={(e) =>
                        updateTrade(r.id, {
                          price: parseFloat(e.target.value) || 0,
                        })
                      }
                      disabled={busy}
                      step="0.01"
                      aria-label="Price"
                    />
                  </RecField>
                  <RecField label="Date">
                    <input
                      className="rec-input"
                      type="date"
                      value={r.date}
                      onChange={(e) =>
                        updateTrade(r.id, { date: e.target.value })
                      }
                      disabled={busy}
                      aria-label="Date"
                    />
                  </RecField>
                  <RecField label="Fee (NT$)">
                    <input
                      className="rec-input"
                      type="number"
                      value={r.fee}
                      onChange={(e) =>
                        updateTrade(r.id, {
                          fee: parseFloat(e.target.value) || 0,
                        })
                      }
                      disabled={busy}
                      min={0}
                      aria-label="Fee"
                    />
                  </RecField>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {state.dividends.length > 0 && (
        <div className="records-preview-section">
          <div className="records-preview-section-title">
            Dividends
            <span className="records-section-count">{state.dividends.length}</span>
          </div>
          <div className="records-preview-rows">
            {state.dividends.map((r) => (
              <div
                key={r.id}
                className={`rec-card${r.include ? "" : " excluded"}${r.duplicate ? " duplicate" : ""}`}
              >
                <div className="rec-card-head">
                  <input
                    type="checkbox"
                    className="rec-check"
                    checked={r.include}
                    onChange={(e) =>
                      updateDividend(r.id, { include: e.target.checked })
                    }
                    disabled={busy}
                    aria-label="Include this dividend"
                  />
                  <span className="records-pill records-pill-div">Dividend</span>
                  <input
                    className="rec-ticker"
                    value={r.ticker}
                    onChange={(e) =>
                      updateDividend(r.id, {
                        ticker: e.target.value.toUpperCase(),
                      })
                    }
                    disabled={busy}
                    placeholder="Ticker"
                    aria-label="Ticker"
                  />
                  {r.duplicate && (
                    <span
                      className="rec-dup-badge"
                      title="A matching dividend already exists in your portfolio"
                    >
                      Already imported
                    </span>
                  )}
                  <button
                    type="button"
                    className="rec-remove"
                    onClick={() => removeDividend(r.id)}
                    disabled={busy}
                    title="Remove this row"
                    aria-label="Remove row"
                  >
                    ×
                  </button>
                </div>
                <div className="rec-card-grid rec-card-grid-div">
                  <RecField label="Amount (NT$)">
                    <input
                      className="rec-input"
                      type="number"
                      value={r.amount}
                      onChange={(e) =>
                        updateDividend(r.id, {
                          amount: parseFloat(e.target.value) || 0,
                        })
                      }
                      disabled={busy}
                      step="0.01"
                      aria-label="Amount"
                    />
                  </RecField>
                  <RecField label="Pay date">
                    <input
                      className="rec-input"
                      type="date"
                      value={r.date}
                      onChange={(e) =>
                        updateDividend(r.id, { date: e.target.value })
                      }
                      disabled={busy}
                      aria-label="Pay date"
                    />
                  </RecField>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {error && <div className="error" style={{ fontSize: 12 }}>{error}</div>}

      <div className="records-preview-actions">
        <button
          type="button"
          className="secondary"
          onClick={onCancel}
          disabled={busy}
        >
          Cancel
        </button>
        <button
          type="button"
          onClick={onConfirm}
          disabled={busy || totalSelected === 0}
          title="Save selected rows to your portfolio"
        >
          {busy
            ? "Saving…"
            : `Add ${totalSelected} to portfolio`}
        </button>
      </div>
    </div>
  );
}

function MessageMetaStrip({
  meta,
  sourceCount,
}: {
  meta: MessageMeta;
  sourceCount: number;
}) {
  const [open, setOpen] = useState(false);
  const seconds = meta.durationMs ? (meta.durationMs / 1000).toFixed(1) : null;
  const hasQueries = meta.queries.length > 0;

  let label: string;
  if (meta.interrupted) {
    label = "Stopped" + (seconds ? ` after ${seconds}s` : "");
  } else if (hasQueries) {
    const sourcesPart = sourceCount > 0 ? ` · ${sourceCount} source${sourceCount === 1 ? "" : "s"}` : "";
    const timePart = seconds ? ` · ${seconds}s` : "";
    label = `Searched the web${sourcesPart}${timePart}`;
  } else {
    label = `Thought for ${seconds ?? "0"}s`;
  }

  const expandable = hasQueries;

  return (
    <button
      type="button"
      className={`message-meta${open ? " open" : ""}${expandable ? " expandable" : ""}`}
      onClick={() => expandable && setOpen((o) => !o)}
      disabled={!expandable}
      aria-expanded={expandable ? open : undefined}
    >
      <span className="message-meta-row">
        <span className="message-meta-label">{label}</span>
        {expandable && <span className="message-meta-chevron" aria-hidden>›</span>}
      </span>
      {open && hasQueries && (
        <ul className="message-meta-queries">
          {meta.queries.map((q, i) => (
            <li key={i}>
              <span className="message-meta-q-icon" aria-hidden>⌕</span> {q}
            </li>
          ))}
        </ul>
      )}
    </button>
  );
}

// Lucide-style 16px line icons used in the input row. `currentColor` lets
// the existing button hover state recolor them (neutral → accent blue).

function PaperclipIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
    </svg>
  );
}

function PhoneScanIcon() {
  // Phone outline + a 2x2 QR-style block inside, hinting at "scan a QR with
  // your phone". The four square dots line up with how the QR position
  // markers look at thumbnail size.
  return (
    <svg
      width="17"
      height="17"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <rect x="6" y="2" width="12" height="20" rx="2.6" />
      <line x1="10.5" y1="5" x2="13.5" y2="5" />
      <rect x="8.6" y="9" width="2.6" height="2.6" rx="0.4" fill="currentColor" stroke="none" />
      <rect x="12.8" y="9" width="2.6" height="2.6" rx="0.4" fill="currentColor" stroke="none" />
      <rect x="8.6" y="13.2" width="2.6" height="2.6" rx="0.4" fill="currentColor" stroke="none" />
      <rect x="12.8" y="13.2" width="2.6" height="2.6" rx="0.4" fill="currentColor" stroke="none" />
    </svg>
  );
}

function SpinnerIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      className="assistant-spin"
      aria-hidden
    >
      <path d="M12 3a9 9 0 1 0 9 9" />
    </svg>
  );
}

