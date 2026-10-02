"use client";
import { useState } from "react";
import { ArrowUpRight, X } from "lucide-react";
import { Modal } from "./Modal";
import { APPSTORE_URL, TESTFLIGHT_URL } from "./links";

export function DownloadAction({ device }: { device: "Mac" | "iPad" | "iPhone" }) {
  const [open, setOpen] = useState(false);
  return <>
    <button type="button" className="arrow-button" onClick={() => setOpen(true)}>Download for {device}<ArrowUpRight size={18} aria-hidden="true" /></button>
    {open && <Modal className="download-dialog" labelledBy={`download-${device}`} onClose={() => setOpen(false)}>
      <button data-initial-focus type="button" className="icon-button dialog-close" onClick={() => setOpen(false)} aria-label="Close download options" title="Close"><X size={22} /></button>
      <img src="/app-icon.png" width="56" height="56" alt="" /><p className="page-label">Get RSSum</p><h2 id={`download-${device}`}>RSSum for {device}</h2>
      <p>{device === "Mac" ? "Native for Apple Silicon. Choose your download below." : "Available on the App Store for iPhone and iPad."}</p>
      <div className="dialog-actions">
        <a className={device === "Mac" ? "secondary-button" : "arrow-button"} href={APPSTORE_URL} target="_blank" rel="noreferrer">View on the App Store<ArrowUpRight size={18} aria-hidden="true" /></a>
        <a className={device === "Mac" ? "arrow-button" : "text-link"} href={TESTFLIGHT_URL} target="_blank" rel="noreferrer">Continue on TestFlight<ArrowUpRight size={18} aria-hidden="true" /></a>
      </div>
    </Modal>}
  </>;
}
