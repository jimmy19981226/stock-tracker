import { useEffect, useRef, useState, type ReactNode } from "react";

/** Flashes green (up) / red (down) for ~0.9s whenever `value` changes. Wrap any
 *  live number: <FlashValue value={n}>{formatted}</FlashValue>. The flash keys
 *  off the raw number, while the children render whatever formatted text. */
export function FlashValue({
  value,
  className = "",
  children,
}: {
  value: number | null | undefined;
  className?: string;
  children: ReactNode;
}) {
  const [flash, setFlash] = useState<"up" | "down" | null>(null);
  const prev = useRef<number | null>(null);
  const timer = useRef<number | undefined>(undefined);

  useEffect(() => {
    const cur = value ?? null;
    const p = prev.current;
    if (cur != null && p != null && cur !== p) {
      setFlash(cur > p ? "up" : "down");
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => setFlash(null), 900);
    }
    if (cur != null) prev.current = cur;
    return () => window.clearTimeout(timer.current);
  }, [value]);

  return (
    <span className={`${className}${flash ? ` tick-${flash}` : ""}`}>{children}</span>
  );
}
