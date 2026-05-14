import { useEffect, useRef } from "react";
import { createPortal } from "react-dom";
import type { ReactNode } from "react";

interface Props {
  open: boolean;
  title: string;
  /** Optional secondary explanation under the title. ReactNode so callers
   *  can include `<strong>` for the data being acted on. */
  message?: ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  /** Render the confirm button in red — for destructive actions. */
  danger?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * In-app replacement for `window.confirm()` so destructive prompts inherit
 * the dark theme and don't pop a stark native dialog.
 *
 * Esc cancels, Enter confirms — matching the existing assistant chat
 * delete modal so muscle memory carries over.
 */
export function ConfirmModal({
  open,
  title,
  message,
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
  danger = false,
  onConfirm,
  onCancel,
}: Props) {
  useEffect(() => {
    if (!open) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        e.preventDefault();
        onCancel();
      } else if (e.key === "Enter") {
        e.preventDefault();
        onConfirm();
      }
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, onConfirm, onCancel]);

  // Focus the confirm button on open (so Enter / Space immediately commits)
  // but DON'T let the browser scroll the page to bring it into view — the
  // modal is already inside a fixed overlay, so any scroll is a jarring
  // jump on the underlying page.
  const confirmBtnRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!open) return;
    confirmBtnRef.current?.focus({ preventScroll: true });
  }, [open]);

  if (!open) return null;

  // Portal to document.body so the modal escapes any transformed ancestor
  // (e.g. .panel's panel-fade-in animation leaves a transform behind, which
  // would otherwise re-anchor `position: fixed` to the panel instead of
  // the viewport — manifesting as the dialog appearing wherever the user
  // had scrolled the page to).
  return createPortal(
    <div
      className="modal-backdrop confirm-modal-backdrop"
      onClick={onCancel}
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-modal-title"
    >
      <div className="modal confirm-modal" onClick={(e) => e.stopPropagation()}>
        <h3 id="confirm-modal-title" className="confirm-modal-title">
          {title}
        </h3>
        {message && <div className="confirm-modal-message">{message}</div>}
        <div className="confirm-modal-actions">
          <button type="button" className="secondary" onClick={onCancel}>
            {cancelLabel}
          </button>
          <button
            ref={confirmBtnRef}
            type="button"
            className={danger ? "confirm-modal-danger" : ""}
            onClick={onConfirm}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
