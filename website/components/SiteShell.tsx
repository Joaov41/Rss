"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { type MouseEvent, useEffect, useLayoutEffect, useRef, useState } from "react";
import { BookOpen, Download, House, LayoutGrid, LifeBuoy, Menu, MessageCircleQuestion, X } from "lucide-react";

const navIcons = { Home: House, Features: LayoutGrid, FAQ: MessageCircleQuestion, Support: LifeBuoy, Download, Tutorial: BookOpen };

type HeaderSnapshot = {
  bounds: DOMRect;
  radius: string;
  links: Map<HTMLElement, { bounds: DOMRect; opacity: string }>;
};

const navItems = [
  ["Home", "/"],
  ["Features", "/features"],
  ["FAQ", "/faq"],
  ["Support", "/support"],
  ["Download", "/download"],
  ["Tutorial", "/tutorial/"],
] as const;

export function SiteHeader() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [compact, setCompact] = useState(false);
  const [docked, setDocked] = useState(false);
  const header = useRef<HTMLElement>(null);
  const dockTarget = useRef(false);
  const beforeMorph = useRef<HeaderSnapshot | null>(null);
  const toggle = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (open) return;
    let frame = 0;
    const hero = pathname === "/" ? document.querySelector<HTMLElement>(".cinema-hero, .rd-hero") : null;
    let heroEnd = Infinity;
    const update = () => {
      frame = 0;
      // Separate thresholds prevent flickering near the changeover point.
      setCompact(current => window.scrollY > (current ? 32 : 96));
      const next = window.scrollY > heroEnd + (dockTarget.current ? -24 : 24);
      if (next !== dockTarget.current) {
        const surface = header.current?.querySelector<HTMLElement>(".header-glass");
        beforeMorph.current = hero && surface && window.matchMedia("(min-width: 1024px) and (prefers-reduced-motion: no-preference)").matches
          ? {
              bounds: surface.getBoundingClientRect(),
              radius: getComputedStyle(surface).borderRadius,
              links: new Map(Array.from(header.current!.querySelectorAll<HTMLElement>("a"), link => [link, { bounds: link.getBoundingClientRect(), opacity: getComputedStyle(link).opacity }])),
            }
          : null;
        dockTarget.current = next;
        setDocked(next);
      }
    };
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(update);
    };
    const measure = () => {
      // Dock to the side as soon as the reader starts scrolling the home page.
      heroEnd = hero ? 80 : Infinity;
      onScroll();
    };
    const observer = hero ? new ResizeObserver(measure) : null;
    if (hero) observer?.observe(hero);
    measure();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", measure);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", measure);
      observer?.disconnect();
      window.cancelAnimationFrame(frame);
    };
  }, [open, pathname]);
  useLayoutEffect(() => {
    const before = beforeMorph.current;
    beforeMorph.current = null;
    const element = header.current;
    const surface = element?.querySelector<HTMLElement>(".header-glass");
    const motion = window.matchMedia("(min-width: 1024px) and (prefers-reduced-motion: no-preference)");
    if (!before || !element || !surface || pathname !== "/" || !motion.matches) return;

    const after = surface.getBoundingClientRect();
    const timing = { duration: 520, easing: "cubic-bezier(0.4, 0, 0.2, 1)" };
    const foldWidth = Math.min(before.bounds.width, after.width);
    const foldHeight = Math.min(before.bounds.height, after.height);
    const foldLeft = Math.max(before.bounds.right, after.right) - foldWidth - after.left;
    const foldTop = Math.min(before.bounds.top, after.top) - after.top;
    element.dataset.morphing = "true";
    // Morph only the glass surface; translate links independently so text never stretches.
    const animations = [surface.animate([
      { left: `${before.bounds.left - after.left}px`, top: `${before.bounds.top - after.top}px`, width: `${before.bounds.width}px`, height: `${before.bounds.height}px`, borderRadius: before.radius },
      { left: `${foldLeft}px`, top: `${foldTop}px`, width: `${foldWidth}px`, height: `${foldHeight}px`, borderRadius: "36px", offset: .45 },
      { left: "0px", top: "0px", width: `${after.width}px`, height: `${after.height}px`, borderRadius: getComputedStyle(surface).borderRadius },
    ], timing)];
    for (const [link, previous] of before.links) {
      const current = link.getBoundingClientRect();
      const origin = `translate(${previous.bounds.left - current.left}px, ${previous.bounds.top - current.top}px)`;
      animations.push(link.animate([
        { transform: origin, opacity: previous.opacity },
        { transform: origin, opacity: 0, offset: .12 },
        { transform: "translate(0, 0)", opacity: 0, offset: .8 },
        { transform: "translate(0, 0)", opacity: 1 },
      ], { duration: 650, easing: "linear" }));
    }
    const stop = () => {
      animations.forEach(animation => animation.cancel());
      delete element.dataset.morphing;
      window.removeEventListener("resize", stop);
      motion.removeEventListener("change", stop);
    };
    window.addEventListener("resize", stop);
    motion.addEventListener("change", stop);
    Promise.all(animations.map(animation => animation.finished)).then(stop, () => {});
    return stop;
  }, [docked, pathname]);
  useEffect(() => {
    if (!open) return;
    const close = (event: KeyboardEvent) => { if (event.key === "Escape") { setOpen(false); toggle.current?.focus(); } };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [open]);

  function goHome(event: MouseEvent<HTMLAnchorElement>) {
    setOpen(false);
    if (pathname !== "/" || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    window.scrollTo({ top: 0, behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth" });
  }

  return (
    <header ref={header} className="site-header" data-compact={compact ? "true" : undefined} data-side-nav={pathname === "/" ? "true" : undefined} data-docked={pathname === "/" && docked ? "true" : undefined}>
      <span className="header-glass" aria-hidden="true" />
      <Link className="brand" href="/" aria-label="RSSum home" onClick={goHome}>
        <img src="/app-icon.png" alt="" width="40" height="40" />
        <span>RSSum</span>
      </Link>
      <button
        className="menu-toggle icon-button"
        ref={toggle}
        type="button"
        aria-label={open ? "Close menu" : "Open menu"}
        title={open ? "Close menu" : "Open menu"}
        aria-controls="main-navigation"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        {open ? <X size={22} /> : <Menu size={22} />}
      </button>
      <nav id="main-navigation" className={open ? "site-nav open" : "site-nav"} aria-label="Main navigation">
        {navItems.filter(([label]) => label !== "Download").map(([label, href]) => {
          const Icon = navIcons[label];
          return (
            <Link
              key={href}
              href={href}
              data-active={pathname === href ? "true" : undefined}
              aria-current={pathname === href ? "page" : undefined}
              title={label}
              onClick={label === "Home" ? goHome : () => setOpen(false)}
            >
              <Icon className="nav-icon" size={20} strokeWidth={1.6} aria-hidden="true" /><span>{label}</span>
            </Link>
          );
        })}
      </nav>
      <Link className="header-cta" href="/download" title="Get RSSum" onClick={() => setOpen(false)}>
        <Download className="nav-icon" size={20} strokeWidth={1.6} aria-hidden="true" /><span>Get RSSum</span>
      </Link>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="footer-brand">
        <img src="/app-icon.png" alt="" width="38" height="38" />
        <div>
          <strong>RSSum</strong>
          <span>RSS, Reddit, YouTube &amp; podcasts.</span>
        </div>
      </div>
      <nav aria-label="Footer navigation">
        {navItems.map(([label, href]) => (
          <Link key={href} href={href}>{label}</Link>
        ))}
        <a href="https://github.com/Joaov41/Rss" target="_blank" rel="noreferrer">GitHub</a>
      </nav>
      <div className="footer-legal">
        <span>© 2026 RSSum.</span>
        <span>Native for Mac, iPad &amp; iPhone.</span>
        <span><Link href="/privacy">Privacy</Link> · <Link href="/terms">Terms</Link></span>
      </div>
    </footer>
  );
}

export function SiteShell({ children }: { children: React.ReactNode }) {
  return (
    <>
      <a className="skip-link" href="#main-content">Skip to content</a>
      <SiteHeader />
      {children}
      <SiteFooter />
    </>
  );
}
