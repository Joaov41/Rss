"use client";
import { useEffect, useRef } from "react";

export function Modal({ children, onClose, className, labelledBy, onKeyDown }: { children: React.ReactNode; onClose: () => void; className: string; labelledBy: string; onKeyDown?: React.KeyboardEventHandler<HTMLDialogElement> }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    const overflow = document.body.style.overflow;
    const trigger = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    dialog?.showModal();
    dialog?.querySelector<HTMLElement>("[data-initial-focus]")?.focus();
    document.body.style.overflow = "hidden";
    return () => {
      dialog?.close();
      document.body.style.overflow = overflow;
      trigger?.focus({ preventScroll: true });
    };
  }, []);
  return <dialog ref={ref} className={className} aria-labelledby={labelledBy} onClose={event => {
    // Ignore a queued close event if the effect has already reopened the dialog.
    if (!event.currentTarget.open) onClose();
  }} onKeyDown={onKeyDown} onClick={event => {
    if (event.target !== event.currentTarget) return;
    const rect = event.currentTarget.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) onClose();
  }}>{children}</dialog>;
}
