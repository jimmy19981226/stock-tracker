import { useEffect, useRef, useState } from "react";
import {
  api,
  type ChatDetail,
  type ChatMessage,
  type ChatSummary,
} from "../api";

interface Props {
  onClose: () => void;
}

const SUGGESTIONS = [
  "How is 2330 (台積電)'s monthly revenue trending?",
  "Is 2330's gross margin improving over the last 4 quarters?",
  "Which of my holdings has the strongest YoY revenue growth?",
  "Compare 2330's current price to its 1-year analyst target.",
  "Top 3 winners by % return?",
  "Which positions are losing money?",
  "Best dividend month in 2025?",
  "Summarize my 2024 performance.",
];

const LAST_CHAT_KEY = "assistant.lastChatId";

type View = "messages" | "list";

export function AssistantPanel({ onClose }: Props) {
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
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

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
    try {
      const reply = await api.aiChat(activeChatId, trimmed);
      setActiveChatId(reply.chat_id);
      setActiveTitle(reply.title);
      localStorage.setItem(LAST_CHAT_KEY, String(reply.chat_id));
      setMessages([...optimistic, reply.message]);
      refreshChats();
    } catch (err) {
      // Roll the optimistic user message back so the chat doesn't show
      // a question that was never persisted.
      setMessages(messages);
      setError(err instanceof Error ? err.message : "Request failed");
    } finally {
      setBusy(false);
    }
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
              <div>
                <div
                  className="muted"
                  style={{ fontSize: 12, marginBottom: 10 }}
                >
                  Ask anything about your portfolio. Suggestions:
                </div>
                <div
                  style={{ display: "flex", flexDirection: "column", gap: 6 }}
                >
                  {SUGGESTIONS.map((s) => (
                    <button
                      key={s}
                      type="button"
                      className="secondary"
                      onClick={() => send(s)}
                      style={{
                        textAlign: "left",
                        padding: "8px 12px",
                        fontSize: 12.5,
                        fontWeight: 400,
                        color: "var(--text-2)",
                        lineHeight: 1.4,
                      }}
                    >
                      {s}
                    </button>
                  ))}
                </div>
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
            <button type="submit" disabled={busy || !input.trim()}>
              Send
            </button>
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
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: isUser ? "flex-end" : "flex-start",
        marginBottom: 12,
      }}
    >
      <div
        className="muted"
        style={{
          fontSize: 9,
          fontWeight: 700,
          textTransform: "uppercase",
          letterSpacing: "0.12em",
          marginBottom: 4,
          color: isUser ? "var(--accent)" : "var(--accent-2)",
        }}
      >
        {isUser ? "You" : "Assistant"}
      </div>
      <div
        style={{
          maxWidth: "92%",
          padding: "9px 13px",
          borderRadius: 11,
          fontSize: 13,
          lineHeight: 1.55,
          whiteSpace: "pre-wrap",
          wordBreak: "break-word",
          background: isUser ? "var(--accent-soft)" : "var(--panel-2)",
          border: `1px solid ${isUser ? "var(--border-accent)" : "var(--border-strong)"}`,
          color: "var(--text)",
        }}
      >
        {message.content}
      </div>
    </div>
  );
}
