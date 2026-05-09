import {
  cloneElement,
  Fragment,
  isValidElement,
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
  type Holding,
} from "../api";

interface Props {
  onClose: () => void;
  holdings?: Holding[];
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

export function AssistantPanel({ onClose, holdings = [] }: Props) {
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
    () => pickSuggestions(topTickers, 4, suggestionSeed),
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
                  Ask anything about your portfolio or the market
                </div>
                <div className="assistant-welcome-sub muted">
                  I can analyze your holdings, search the web for fresh news
                  and filings, and pull together the answer with sources.
                  Try one of these:
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
          </div>

          {error && (
            <div className="error" style={{ fontSize: 12 }}>
              {error}
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
              ref={inputRef}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              placeholder="Ask about your portfolio…"
              disabled={busy}
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
              <button type="submit" disabled={!input.trim()}>
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

