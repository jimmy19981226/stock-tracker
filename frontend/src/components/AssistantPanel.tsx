import { useEffect, useMemo, useRef, useState } from "react";
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
    const optimistic: ChatMessage[] = [
      ...messages,
      { role: "user", content: trimmed },
    ];
    setMessages(optimistic);
    setInput("");
    setBusy(true);
    setError(null);
    const controller = new AbortController();
    abortRef.current = controller;
    try {
      const reply = await api.aiChat(activeChatId, trimmed, controller.signal);
      setActiveChatId(reply.chat_id);
      setActiveTitle(reply.title);
      localStorage.setItem(LAST_CHAT_KEY, String(reply.chat_id));
      setMessages([...optimistic, reply.message]);
      refreshChats();
    } catch (err) {
      // User-initiated cancel — keep the question in the chat (the
      // backend may still complete and store the answer; refreshing
      // the chat will pull it in). Just clear busy state.
      if (
        (err instanceof DOMException && err.name === "AbortError") ||
        (err instanceof Error && err.message.toLowerCase().includes("abort"))
      ) {
        // Pull whatever the backend ended up storing so the user can see
        // a late-arriving answer if one was generated.
        if (activeChatId != null) {
          refreshChats();
          api
            .getChat(activeChatId)
            .then((d) => setMessages(d.messages))
            .catch(() => {
              /* leave optimistic state */
            });
        }
        setError(null);
      } else {
        setMessages(messages);
        setError(err instanceof Error ? err.message : "Request failed");
      }
    } finally {
      setBusy(false);
      abortRef.current = null;
    }
  }

  function stopGeneration() {
    abortRef.current?.abort();
  }

  async function handleDelete(id: number) {
    if (!confirm("Delete this conversation?")) return;
    try {
      await api.deleteChat(id);
      if (id === activeChatId) newChat();
      await refreshChats();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Delete failed");
    }
  }

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
                  Ask anything about your portfolio
                </div>
                <div className="assistant-welcome-sub muted">
                  I can analyze trends, compare positions, and surface insights
                  from your live data. Try one of these:
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
              messages.map((m, i) => <Bubble key={i} message={m} />)
            )}
            {busy && (
              <div
                className="muted"
                style={{ fontSize: 12, padding: "6px 4px" }}
              >
                <span className="thinking-dots">
                  <span /> <span /> <span />
                </span>{" "}
                Thinking…
              </div>
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

function Bubble({ message }: { message: ChatMessage }) {
  const isUser = message.role === "user";
  return (
    <div className={`bubble-row ${isUser ? "bubble-row-user" : "bubble-row-assistant"}`}>
      <div className="bubble-role">
        {!isUser && <span className="bubble-role-mark" aria-hidden>✦</span>}
        {isUser ? "You" : "Assistant"}
      </div>
      <div className={`bubble ${isUser ? "bubble-user" : "bubble-assistant"}`}>
        {isUser ? (
          message.content
        ) : (
          <div className="md-content">
            <ReactMarkdown
              remarkPlugins={[remarkGfm]}
              // Keep links safe — open in new tab, no referrer.
              components={{
                a: (props) => (
                  <a {...props} target="_blank" rel="noopener noreferrer" />
                ),
              }}
            >
              {message.content}
            </ReactMarkdown>
          </div>
        )}
      </div>
    </div>
  );
}
