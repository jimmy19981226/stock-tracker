/** Low-level helpers the agent executor uses to drive the real UI:
 *  finding tagged elements, waiting for them to mount, and writing values
 *  into React-controlled inputs so the components' own state updates. */

export const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function agentEl(id: string): HTMLElement | null {
  return document.querySelector<HTMLElement>(`[data-agent="${CSS.escape(id)}"]`);
}

function isVisible(el: HTMLElement): boolean {
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
}

/** Poll until an element tagged `data-agent={id}` is mounted and visible, or
 *  the timeout elapses (a freshly-navigated view needs a frame to render). */
export async function waitForAgent(
  id: string,
  timeout = 4000,
): Promise<HTMLElement | null> {
  const start = performance.now();
  while (performance.now() - start < timeout) {
    const el = agentEl(id);
    if (el && isVisible(el)) return el;
    await sleep(60);
  }
  return agentEl(id);
}

/** Set the value of a controlled <input>/<select>/<textarea> the way React
 *  expects: call the native value setter, then dispatch input + change so the
 *  component's onChange fires and its state syncs. */
export function setReactValue(
  el: HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement,
  value: string,
): void {
  const proto = Object.getPrototypeOf(el);
  const desc = Object.getOwnPropertyDescriptor(proto, "value");
  if (desc && desc.set) desc.set.call(el, value);
  else (el as { value: string }).value = value;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
}

/** Type `text` into a field one character at a time so the user sees it being
 *  filled in, keeping the React state in sync the whole way. */
export async function typeInto(
  el: HTMLInputElement | HTMLTextAreaElement,
  text: string,
  perChar = 55,
): Promise<void> {
  el.focus();
  setReactValue(el, "");
  let cur = "";
  for (const ch of text) {
    cur += ch;
    setReactValue(el, cur);
    await sleep(perChar);
  }
}

export function centerOf(el: HTMLElement): { x: number; y: number } {
  const r = el.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
}

export const todayISO = (): string => {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
};
