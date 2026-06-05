/** Agentic UI driver. The assistant's planner returns an ordered list of
 *  steps (navigate, open a stock, fill + submit the real forms, highlight a
 *  card); this provider PLAYS them out over the live app with a floating
 *  cursor that glides to each target, a spotlight ring that pulses on it, and
 *  character-by-character typing — so the user watches the app operate itself.
 *
 *  The executor only talks to the DOM through `data-agent="…"` tags and the
 *  components' own onChange/onClick handlers, so it stays decoupled from app
 *  state and there's a single seam (the tags) to keep in sync. */
import {
  createContext,
  useCallback,
  useContext,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { AgentPlan, AgentStep } from "../api";
import {
  agentEl,
  centerOf,
  setReactValue,
  sleep,
  todayISO,
  typeInto,
  waitForAgent,
} from "./dom";

interface AgentApi {
  running: boolean;
  status: string;
  runPlan: (plan: AgentPlan) => Promise<void>;
  stop: () => void;
}

const AgentContext = createContext<AgentApi | null>(null);

export function useAgent(): AgentApi | null {
  return useContext(AgentContext);
}

interface CursorState {
  x: number;
  y: number;
  visible: boolean;
  pressing: boolean;
}
interface SpotState {
  x: number;
  y: number;
  w: number;
  h: number;
  visible: boolean;
}

const HIDDEN_CURSOR: CursorState = { x: 0, y: 0, visible: false, pressing: false };
const HIDDEN_SPOT: SpotState = { x: 0, y: 0, w: 0, h: 0, visible: false };

export function AgentProvider({ children }: { children: ReactNode }) {
  const [running, setRunning] = useState(false);
  const [status, setStatus] = useState("");
  const [cursor, setCursor] = useState<CursorState>(HIDDEN_CURSOR);
  const [spot, setSpot] = useState<SpotState>(HIDDEN_SPOT);
  const abortRef = useRef(false);

  const stop = useCallback(() => {
    abortRef.current = true;
  }, []);

  // The whole executor lives in one stable callback. It only uses the (stable)
  // state setters + the DOM, so there are no stale-closure hazards.
  const runPlan = useCallback(async (plan: AgentPlan) => {
    abortRef.current = false;
    setRunning(true);
    // Park the cursor mid-screen so the first move is a short glide, not a
    // swoop in from the corner.
    setCursor({
      x: window.innerWidth / 2,
      y: window.innerHeight * 0.42,
      visible: true,
      pressing: false,
    });
    await sleep(220);

    const aborted = () => abortRef.current;

    async function pointAt(el: HTMLElement, scroll = true): Promise<void> {
      if (scroll) {
        el.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" });
        await sleep(420);
      }
      const c = centerOf(el);
      const r = el.getBoundingClientRect();
      setCursor((p) => ({ ...p, x: c.x, y: c.y, visible: true, pressing: false }));
      setSpot({ x: r.left, y: r.top, w: r.width, h: r.height, visible: true });
      await sleep(600); // matches the cursor/spotlight CSS transition
    }

    async function press(el: HTMLElement): Promise<void> {
      setCursor((p) => ({ ...p, pressing: true }));
      await sleep(150);
      setCursor((p) => ({ ...p, pressing: false }));
      el.click();
      await sleep(140);
    }

    async function fill(id: string, value: string): Promise<void> {
      const el = agentEl(id) as HTMLInputElement | null;
      if (!el) return;
      await pointAt(el);
      await typeInto(el, value);
      await sleep(120);
    }

    async function choose(id: string, value: string): Promise<void> {
      const el = agentEl(id) as HTMLSelectElement | null;
      if (!el) return;
      await pointAt(el);
      setReactValue(el, value);
      await sleep(260);
    }

    // True when we're on the Overview landing page (cards present, no in-market
    // nav). The tabs/forms only exist inside a market, so most actions must
    // enter one first.
    function onOverview(): boolean {
      return !!agentEl("overview-tw") && !agentEl("nav-dashboard");
    }

    const marketOfTicker = (t: string): "TW" | "US" =>
      /^\d/.test((t || "").trim()) ? "TW" : "US";

    async function ensureMarket(code?: string): Promise<void> {
      if (!onOverview()) return;
      const c = (code || "TW").toUpperCase() === "US" ? "us" : "tw";
      const card = agentEl(`overview-${c}`);
      if (card) {
        await pointAt(card);
        await press(card);
        await sleep(440); // portfolio view mounts
      }
    }

    async function navigate(view?: string): Promise<void> {
      const v = view || "dashboard";
      const btn = agentEl(`nav-${v}`);
      if (btn) {
        await pointAt(btn);
        await press(btn);
      }
      await sleep(320); // let the new view mount
    }

    async function openStock(ticker?: string): Promise<void> {
      if (!ticker) return;
      await ensureMarket(marketOfTicker(ticker));
      await navigate("dashboard");
      const row = await waitForAgent(`holding-${ticker.toUpperCase()}`, 3000);
      if (row) {
        await pointAt(row);
        await press(row);
        await sleep(500); // modal lazy-loads + fetches
      }
    }

    async function closeModal(): Promise<void> {
      const close = document.querySelector<HTMLElement>(".stock-modal [data-agent='modal-close'], .stock-modal .modal-close");
      if (close) {
        await pointAt(close, false);
        await press(close);
      } else {
        window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
        document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
      }
      await sleep(360);
    }

    // The planner occasionally drops a code into `target` instead of `ticker`;
    // accept either so a misfiled field doesn't blank out the form.
    const tickerOf = (step: AgentStep) => (step.ticker || step.target || "").toUpperCase();

    async function addTrade(step: AgentStep): Promise<void> {
      const m = step.market || marketOfTicker(tickerOf(step));
      await ensureMarket(m);
      await navigate("trades");
      if (!(await waitForAgent("trade-ticker", 4000))) return;
      if (step.market) await choose("trade-market", step.market);
      if (step.trade_type) await choose("trade-type", step.trade_type);
      await fill("trade-ticker", tickerOf(step));
      if (step.shares != null) await fill("trade-shares", String(step.shares));
      if (step.price != null) await fill("trade-price", String(step.price));
      await fill("trade-date", step.date || todayISO());
      if (step.fee != null) await fill("trade-fee", String(step.fee));
      if (step.notes) await fill("trade-notes", step.notes);
      const submit = agentEl("trade-submit");
      if (submit) {
        await pointAt(submit);
        await press(submit);
        await sleep(700);
      }
    }

    async function addDividend(step: AgentStep): Promise<void> {
      const m = step.market || marketOfTicker(tickerOf(step));
      await ensureMarket(m);
      await navigate("dividends");
      if (!(await waitForAgent("dividend-ticker", 4000))) return;
      if (step.market) await choose("dividend-market", step.market);
      await fill("dividend-ticker", tickerOf(step));
      if (step.amount != null) await fill("dividend-amount", String(step.amount));
      await fill("dividend-date", step.date || todayISO());
      if (step.notes) await fill("dividend-notes", step.notes);
      const submit = agentEl("dividend-submit");
      if (submit) {
        await pointAt(submit);
        await press(submit);
        await sleep(700);
      }
    }

    async function filterTrades(step: AgentStep): Promise<void> {
      await ensureMarket(step.market || (tickerOf(step) ? marketOfTicker(tickerOf(step)) : "TW"));
      await navigate("trades");
      if (step.ticker || step.target) await fill("trade-filter-ticker", tickerOf(step));
      if (step.trade_type) await choose("trade-filter-type", step.trade_type);
      if (step.status) await choose("trade-filter-status", step.status);
    }

    async function highlight(target?: string): Promise<void> {
      if (!target) return;
      const id = target.startsWith("holding-") ? target.toUpperCase().replace("HOLDING-", "holding-") : `summary-${target}`;
      const tkr = id.startsWith("holding-") ? id.slice("holding-".length) : "";
      await ensureMarket(tkr ? marketOfTicker(tkr) : "TW");
      await navigate("dashboard");
      const el = await waitForAgent(id, 2500);
      if (!el) return;
      await pointAt(el);
      el.classList.add("agent-flash");
      await sleep(1500);
      el.classList.remove("agent-flash");
    }

    async function playStep(step: AgentStep): Promise<void> {
      switch (step.action) {
        case "navigate": { await ensureMarket(step.market); return navigate(step.view); }
        case "open_stock": return openStock(step.ticker || step.target);
        case "close_modal": return closeModal();
        case "add_trade": return addTrade(step);
        case "add_dividend": return addDividend(step);
        case "filter_trades": return filterTrades(step);
        case "highlight": return highlight(step.target);
        case "note": { await sleep(700); return; }
        default: return;
      }
    }

    try {
      for (const step of plan.steps) {
        if (aborted()) break;
        setStatus(step.say || "");
        await playStep(step);
        await sleep(260); // a beat between steps so it reads clearly
      }
    } finally {
      setStatus("");
      setRunning(false);
      setCursor((p) => ({ ...p, visible: false }));
      setSpot(HIDDEN_SPOT);
    }
    // setters are stable; DOM is read live — no extra deps needed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <AgentContext.Provider value={{ running, status, runPlan, stop }}>
      {children}
      {spot.visible && (
        <div
          className="agent-spotlight"
          style={{ left: spot.x, top: spot.y, width: spot.w, height: spot.h }}
          aria-hidden
        />
      )}
      {cursor.visible && (
        <div
          className="agent-cursor"
          data-pressing={cursor.pressing || undefined}
          style={{ transform: `translate(${cursor.x}px, ${cursor.y}px)` }}
          aria-hidden
        >
          <svg width="26" height="30" viewBox="0 0 26 30" fill="none">
            <path
              d="M3 2.5 L21 13.5 L13.2 15.2 L18 24.5 L14 26.5 L9.4 17 L3.4 22 Z"
              fill="#0b1020"
              stroke="#ffffff"
              strokeWidth="1.6"
              strokeLinejoin="round"
            />
          </svg>
          {status && <span className="agent-cursor-label">{status}</span>}
        </div>
      )}
    </AgentContext.Provider>
  );
}
