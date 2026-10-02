"use client";
import { useRef, useState } from "react";
import { Headphones, Maximize2, MessageCircle, Pause, Play, Rss, SquarePlay } from "lucide-react";
import { ProductStage } from "./ProductStage";

const views = [
  { label: "RSS", detail: "Articles worth your time", icon: Rss, image: "/hero-services.png", caption: "Your subscriptions. One reading list.", alt: "RSSum showing the All Articles feed and subscription sidebar" },
  { label: "Reddit", detail: "The whole conversation", icon: MessageCircle, image: "/gallery/set-20260825-1639/gallery-04.png", caption: "Follow communities alongside your articles.", alt: "RSSum showing a Reddit community feed" },
  { label: "YouTube", detail: "Channels you choose", icon: SquarePlay, image: "/gallery/set-20260825-1639/gallery-13.png", caption: "Watch a video, then ask about it.", alt: "A YouTube video inside RSSum with an Ask About This Video action" },
  { label: "Podcasts", detail: "Listen and go deeper", icon: Headphones, image: "/gallery/set-20260825-1639/gallery-17.png", caption: "Listen to an episode without leaving your reader.", alt: "RSSum podcast episode with its embedded audio player" },
];
export function ProductPreview() {
  const [active, setActive] = useState(0);
  const [moving, setMoving] = useState(true);
  const buttons = useRef<(HTMLButtonElement | null)[]>([]);
  const view = views[active];
  return <div className="product-preview">
    <div className="preview-tabs" role="tablist" aria-label="Explore RSSum sources">
      {views.map(({label, detail, icon: Icon}, index) => <button key={label} ref={node => { buttons.current[index] = node; }} id={`preview-tab-${index}`} type="button" role="tab" aria-label={label} aria-selected={active === index} aria-controls="preview-panel" tabIndex={active === index ? 0 : -1} onClick={() => setActive(index)} onKeyDown={event => {
        let next = index;
        if (event.key === "ArrowRight") next = (index + 1) % views.length;
        else if (event.key === "ArrowLeft") next = (index + views.length - 1) % views.length;
        else if (event.key === "Home") next = 0;
        else if (event.key === "End") next = views.length - 1;
        else return;
        event.preventDefault(); setActive(next); buttons.current[next]?.focus();
      }}><Icon size={22} strokeWidth={1.7} aria-hidden="true" /><span><strong>{label}</strong><small>{detail}</small></span></button>)}
    </div>
    <figure id="preview-panel" role="tabpanel" aria-labelledby={`preview-tab-${active}`} tabIndex={0}>
      <ProductStage src={view.image} alt={view.alt} moving={moving} />
      <figcaption><span>{view.caption}</span><div className="preview-tools"><button type="button" className="motion-toggle" onClick={() => setMoving(value => !value)} aria-label={moving ? "Pause product animation" : "Resume product animation"} title={moving ? "Pause product animation" : "Resume product animation"}>{moving ? <Pause size={16} aria-hidden="true" /> : <Play size={16} aria-hidden="true" />}</button><a href={view.image} target="_blank" rel="noreferrer" title="Open full-size screenshot" aria-label="Open full-size screenshot"><Maximize2 size={16} aria-hidden="true" /></a></div></figcaption>
    </figure>
  </div>;
}
