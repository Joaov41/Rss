"use client";
import Image from "next/image";
import { useRef, useState } from "react";
import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, ExternalLink, X } from "lucide-react";
import { Modal } from "./Modal";

const captions = ["Article reader", "Article summary", "Ask about an article", "Reddit feed", "Reddit post and comments", "Comment summary", "Ask about a discussion", "Comment analysis", "Choose a summary scope", "Batch summarization", "Overall summary", "Generated infographic", "YouTube video", "Video summary", "Ask about a video", "Podcast feed", "Embedded podcast player", "Podcast summary", "Playback in your feed", "Local podcast creation"];
const screenshots = captions.map((caption, index) => ({ caption, src: `/gallery/set-20260825-1639/gallery-${String(index + 1).padStart(2, "0")}.png` }));

export function Gallery() {
  const [expanded, setExpanded] = useState(false);
  const [active, setActive] = useState<number | null>(null);
  const expandButton = useRef<HTMLButtonElement>(null);
  const firstAdded = useRef<HTMLButtonElement>(null);
  const selected = active === null ? null : screenshots[active];
  const move = (offset: number) => setActive(value => value === null ? null : (value + offset + screenshots.length) % screenshots.length);
  return <>
    <div id="screenshot-gallery" className="gallery-grid">
      {(expanded ? screenshots : screenshots.slice(0, 4)).map(({src, caption}, index) => <figure key={src} className="gallery-figure">
        <button ref={index === 4 ? firstAdded : undefined} type="button" className="gallery-item device-frame" onClick={() => setActive(index)} aria-label={`Enlarge ${caption.toLowerCase()}`}><Image src={src} alt={`RSSum: ${caption.toLowerCase()}`} width={2360} height={1640} sizes="(max-width: 760px) 90vw, 550px" /></button>
        <figcaption>{caption}</figcaption>
      </figure>)}
    </div>
    <div className="gallery-expand"><button ref={expandButton} className="secondary-button" aria-expanded={expanded} aria-controls="screenshot-gallery" onClick={() => {
      if (expanded) { setExpanded(false); requestAnimationFrame(() => expandButton.current?.scrollIntoView({block: "center"})); }
      else { setExpanded(true); requestAnimationFrame(() => firstAdded.current?.focus({preventScroll: true})); }
    }}>{expanded ? "Show fewer screenshots" : "View the full gallery"}{expanded ? <ArrowUp size={17} aria-hidden="true" /> : <ArrowDown size={17} aria-hidden="true" />}</button></div>
    {selected && <Modal className="lightbox" labelledBy="lightbox-title" onClose={() => setActive(null)} onKeyDown={event => { if (event.key === "ArrowLeft" || event.key === "ArrowRight") { event.preventDefault(); move(event.key === "ArrowLeft" ? -1 : 1); } }}>
      <div className="lightbox-toolbar"><h2 id="lightbox-title">{selected.caption}</h2><a className="icon-button" href={selected.src} target="_blank" rel="noreferrer" aria-label="Open original image" title="Open original image"><ExternalLink size={20} /></a><button data-initial-focus className="icon-button" onClick={() => setActive(null)} aria-label="Close screenshot" title="Close screenshot"><X size={22} /></button></div>
      <div className="lightbox-stage"><img src={selected.src} alt={`RSSum: ${selected.caption.toLowerCase()}`} /></div>
      <div className="lightbox-navigation"><button className="icon-button" onClick={() => move(-1)} aria-label="Previous screenshot" title="Previous screenshot"><ArrowLeft size={22} /></button><button className="icon-button" onClick={() => move(1)} aria-label="Next screenshot" title="Next screenshot"><ArrowRight size={22} /></button></div>
    </Modal>}
  </>;
}
