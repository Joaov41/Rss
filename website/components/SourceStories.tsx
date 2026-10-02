"use client";

import { useEffect, useRef, useState } from "react";
import Image from "next/image";
import { ArrowUpRight, BookOpen, Headphones, Layers, MessageCircle, Rss, SquarePlay, TextQuote } from "lucide-react";

type StoryMode = "original" | "summary" | "overall";

const stories = [
  { name: "RSS", icon: Rss, title: "The articles you follow.", description: "Follow publications in your reading list. Summarize articles and ask questions about what you read.", image: "01", summary: "02", alt: "RSSum article reader", summaryAlt: "An article summary in RSSum" },
  { name: "Reddit", icon: MessageCircle, title: "The whole conversation.", description: "Follow communities and explore their discussions. Summarize posts, comments, or entire subreddits, then ask about the conversation.", image: "05", summary: "06", overall: "11", alt: "A Reddit post and its comments in RSSum", summaryAlt: "A Reddit discussion summary in RSSum", overallAlt: "An overall summary of subreddit discussions in RSSum, grouped by topic with supporting posts and comment sentiments" },
  { name: "YouTube", icon: SquarePlay, title: "Your channels, right here.", description: "Keep up with your channels and watch videos inside RSSum. Get a summary or ask questions about a video.", image: "13", summary: "14", alt: "YouTube playback and Ask About This Video in RSSum", summaryAlt: "A YouTube video summary in RSSum" },
  { name: "Podcasts", icon: Headphones, title: "Listen. Then go deeper.", description: "Play episodes, summarize them, and ask questions. If a podcast has no transcript, RSSum creates one locally.", image: "17", summary: "18", alt: "The embedded podcast player in RSSum", summaryAlt: "A podcast episode summary in RSSum" },
];

export function SourceStories() {
  const [active, setActive] = useState(0);
  const [mode, setMode] = useState<StoryMode>("original");
  const buttons = useRef<(HTMLButtonElement | null)[]>([]);
  const story = stories[active];
  const views = [
    { id: "original" as const, label: "Original", icon: BookOpen, image: story.image, alt: story.alt },
    { id: "summary" as const, label: "Summary", icon: TextQuote, image: story.summary, alt: story.summaryAlt },
    ...(story.overall ? [{ id: "overall" as const, label: "Overall summary", icon: Layers, image: story.overall, alt: story.overallAlt }] : []),
  ];
  const view = views.find(item => item.id === mode) ?? views[0];
  const image = `/gallery/set-20260825-1639/gallery-${view.image}.png`;
  const modes = useRef<(HTMLButtonElement | null)[]>([]);
  const root = useRef<HTMLDivElement>(null);
  function selectSource(index: number) {
    setActive(index);
    if (!stories[index].overall) setMode(current => current === "overall" ? "summary" : current);
  }
  // Links like <a href="#source-reddit"> anywhere on the page open that source's tab.
  useEffect(() => {
    const open = (hash: string) => {
      const index = stories.findIndex(({ name }) => hash === `#source-${name.toLowerCase()}`);
      if (index < 0) return false;
      selectSource(index);
      root.current?.scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth", block: "start" });
      return true;
    };
    const onClick = (event: MouseEvent) => {
      const link = (event.target as Element).closest?.<HTMLAnchorElement>('a[href^="#source-"]');
      if (link && open(link.hash)) { event.preventDefault(); history.replaceState(null, "", link.hash); }
    };
    open(location.hash);
    document.addEventListener("click", onClick);
    return () => document.removeEventListener("click", onClick);
  }, []);
  return <div className="source-stories" ref={root}>
    <div className="story-tabs" role="tablist" aria-label="Choose a source">
      {stories.map(({ name, icon: Icon }, index) => <button key={name} ref={node => { buttons.current[index] = node; }} id={`story-tab-${index}`} type="button" role="tab" aria-controls="story-panel" aria-selected={active === index} tabIndex={active === index ? 0 : -1} onClick={() => selectSource(index)} onKeyDown={event => {
        let next = index;
        if (event.key === "ArrowRight") next = (index + 1) % stories.length;
        else if (event.key === "ArrowLeft") next = (index + stories.length - 1) % stories.length;
        else if (event.key === "Home") next = 0;
        else if (event.key === "End") next = stories.length - 1;
        else return;
        event.preventDefault(); selectSource(next); buttons.current[next]?.focus();
      }}><Icon size={20} strokeWidth={1.6} aria-hidden="true" /><span>{name}</span></button>)}
    </div>
    <div className="story-layout" id="story-panel" role="tabpanel" aria-labelledby={`story-tab-${active}`} tabIndex={0}>
      <figure className="story-figure">
        <a className="device-frame" href={image} target="_blank" rel="noreferrer" aria-label={`Open ${story.name} ${view.label.toLowerCase()} full size`}>
          <Image src={image} alt={view.alt} width={2360} height={1640} loading="eager" sizes="(max-width: 760px) 92vw, (max-width: 1400px) 64vw, 940px" />
        </a>
        <figcaption>{view.id === "overall" ? "An entire subreddit, summarized by topic." : `${story.name} in RSSum`} <a href={image} target="_blank" rel="noreferrer" title="Open full-size screenshot" aria-label="Open full-size screenshot"><ArrowUpRight size={18} aria-hidden="true" /></a></figcaption>
      </figure>
      <div className="story-copy">
        <p className="page-label">{story.name}</p>
        <h3>{story.title}</h3>
        <p>{view.id === "overall" ? "Get an overall summary of an entire subreddit. Bring together posts and comments by topic, see where people agree or disagree, and ask questions about the wider discussion." : story.description}</p>
        <div className="story-modes" data-expanded={views.length > 2 ? "true" : undefined} role="radiogroup" aria-label="Screenshot view">
          {views.map(({ id, label, icon: Icon }, index) => <button ref={node => { modes.current[index] = node; }} type="button" key={id} role="radio" aria-checked={view.id === id} tabIndex={view.id === id ? 0 : -1} onClick={() => setMode(id)} onKeyDown={event => {
            if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
            event.preventDefault();
            const direction = event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 1;
            const next = event.key === "Home" ? 0 : event.key === "End" ? views.length - 1 : (index + direction + views.length) % views.length;
            setMode(views[next].id); modes.current[next]?.focus();
          }}><Icon size={17} aria-hidden="true" /><span>{label}</span></button>)}
        </div>
        <a className="text-link" href="/tutorial/index.html#feature-notes">Explore the tutorial <ArrowUpRight size={17} aria-hidden="true" /></a>
      </div>
    </div>
  </div>;
}
