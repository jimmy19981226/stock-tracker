import { useEffect, useRef, useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import {
  api,
  type MobileSession,
  type MobileSessionPoll,
  type ParsedRecords,
} from "../api";

interface Props {
  /** Called once the phone has uploaded a file and Gemini has parsed it.
   *  The receiver opens the same edit-and-confirm preview card the
   *  desktop paperclip flow uses. */
  onParsed: (records: ParsedRecords, fileName: string) => void;
  onClose: () => void;
}

const POLL_MS = 2000;

export function MobileUploadModal({ onParsed, onClose }: Props) {
  const [session, setSession] = useState<MobileSession | null>(null);
  const [createError, setCreateError] = useState<string | null>(null);
  const [poll, setPoll] = useState<MobileSessionPoll | null>(null);
  const [copied, setCopied] = useState(false);
  // We close the session on unmount so the in-memory bytes are freed even if
  // the user dismissed the modal mid-upload.
  const closedRef = useRef(false);

  // Mint a session on open.
  useEffect(() => {
    let cancelled = false;
    api
      .createMobileSession()
      .then((s) => {
        if (!cancelled) setSession(s);
      })
      .catch((err) => {
        if (!cancelled) {
          setCreateError(err instanceof Error ? err.message : "Failed to create session");
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Poll for status while the session is open and not yet terminal. We
  // deliberately omit `onParsed` from the deps — the parent re-renders
  // (and re-creates that callback) every time `setPoll` fires, which
  // would tear down the effect mid-poll and cause the in-flight tick
  // to bail on its `stopped` check, losing the "ready" event.
  useEffect(() => {
    if (!session) return;
    if (poll?.status === "ready" || poll?.status === "error") return;

    let stopped = false;
    const tick = async () => {
      try {
        const next = await api.pollMobileSession(session.token);
        if (stopped) return;
        setPoll(next);
      } catch (err) {
        if (stopped) return;
        setPoll({
          status: "error",
          file_name: null,
          parsed: null,
          error: err instanceof Error ? err.message : "Poll failed",
        });
      }
    };
    tick();
    const id = window.setInterval(tick, POLL_MS);
    return () => {
      stopped = true;
      clearInterval(id);
    };
  }, [session, poll?.status]);

  // Separate effect: when status flips to "ready", hand the parsed payload
  // up to the parent so it can close the modal and open the preview card.
  // A ref-guarded one-shot so a stale poll can't fire onParsed twice.
  //
  // We dereference onParsed through a ref instead of putting it in the
  // dep array — keeping the effect's identity stable means a fast
  // re-render between setPoll and effect commit can't tear the hand-off
  // down before it actually fires. The ~500ms delay also lets the user
  // see the green "Ready" badge briefly so the close feels intentional
  // rather than the modal vanishing the instant Gemini returns.
  const onParsedRef = useRef(onParsed);
  onParsedRef.current = onParsed;
  const handedOffRef = useRef(false);
  useEffect(() => {
    if (handedOffRef.current) return;
    if (poll?.status === "ready" && poll.parsed) {
      handedOffRef.current = true;
      const records = poll.parsed;
      const fileName = poll.file_name || "phone-upload";
      window.setTimeout(() => {
        onParsedRef.current(records, fileName);
      }, 500);
    }
  }, [poll?.status, poll?.parsed, poll?.file_name]);

  // Free the session bytes server-side when the modal closes for any reason.
  useEffect(() => {
    return () => {
      if (closedRef.current) return;
      closedRef.current = true;
      const tk = session?.token;
      if (tk) {
        api.closeMobileSession(tk).catch(() => {
          /* best-effort */
        });
      }
    };
  }, [session?.token]);

  // Esc to close.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function copyUrl() {
    if (!session) return;
    try {
      await navigator.clipboard.writeText(session.url);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      /* clipboard may be unavailable in non-https; ignore */
    }
  }

  const status = poll?.status ?? "pending";
  const showQr = !!session && status === "pending";

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal mobile-modal" onClick={(e) => e.stopPropagation()}>
        <header className="mobile-modal-header">
          <div>
            <h2 className="mobile-modal-title">📱 Send from your phone</h2>
            <div className="mobile-modal-sub muted">
              Scan with your phone's camera, then upload a screenshot or PDF.
            </div>
          </div>
          <button
            type="button"
            className="secondary assistant-close"
            onClick={onClose}
            title="Close (Esc)"
            aria-label="Close"
          >
            ✕
          </button>
        </header>

        {createError && <div className="error">{createError}</div>}

        {!session && !createError && (
          <div className="empty" style={{ padding: 32 }}>
            Generating session…
          </div>
        )}

        {session && (
          <>
            <div className="mobile-qr-wrap">
              {showQr ? (
                <QRCodeSVG
                  value={session.url}
                  size={240}
                  bgColor="#ffffff"
                  fgColor="#0a0e16"
                  level="M"
                  includeMargin
                />
              ) : (
                <div className="mobile-qr-placeholder">
                  <StatusBadge status={status} />
                </div>
              )}
            </div>

            <div className="mobile-url-row">
              <input
                readOnly
                className="mobile-url-input"
                value={session.url}
                onClick={(e) => (e.target as HTMLInputElement).select()}
                aria-label="Mobile upload URL"
              />
              <button
                type="button"
                className="secondary"
                onClick={copyUrl}
                title="Copy URL"
              >
                {copied ? "✓" : "Copy"}
              </button>
            </div>

            <div className="mobile-status-row">
              <StatusBadge status={status} />
              {poll?.file_name && (
                <span className="muted" style={{ fontSize: 12 }}>
                  · {poll.file_name}
                </span>
              )}
            </div>

            {poll?.error && <div className="error">{poll.error}</div>}

            <div className="mobile-modal-help muted">
              Phone and computer must be on the same Wi-Fi. If your phone
              can't open <code>{session.url.replace(/^https?:\/\//, "")}</code>,
              start the backend with{" "}
              <code>--host 0.0.0.0</code> and allow inbound port{" "}
              {session.url.match(/:(\d+)/)?.[1] ?? "8000"} through the
              firewall.
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function StatusBadge({ status }: { status: string }) {
  const meta: Record<string, { label: string; className: string }> = {
    pending: { label: "Waiting for phone…", className: "pending" },
    received: { label: "File received · queued for AI", className: "working" },
    parsing: { label: "AI is reading your file…", className: "working" },
    ready: { label: "Ready", className: "ok" },
    error: { label: "Error", className: "err" },
  };
  const m = meta[status] ?? { label: status, className: "pending" };
  return (
    <span className={`mobile-status-badge ${m.className}`}>
      <span className="mobile-status-dot" aria-hidden />
      {m.label}
    </span>
  );
}
