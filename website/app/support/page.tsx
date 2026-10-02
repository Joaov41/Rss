import type { Metadata } from "next";
import Link from "next/link";
import { PageIntro } from "@/components/PageIntro";
import { SiteShell } from "@/components/SiteShell";

export const metadata: Metadata = { title: "Support" };

const resources = [
  ["Browse the FAQ", "Setup tips, troubleshooting, and common questions — all in one place.", "Open FAQ", "/faq"],
  ["Download the app", "Grab the latest macOS, iPad, and iPhone builds — all free.", "Go to downloads", "/download"],
  ["GitHub issues", "Check known problems, report a bug, or follow what's coming next.", "View issues", "https://github.com/Joaov41/Rss/issues"],
] as const;

export default function SupportPage() {
  return (
    <SiteShell>
      <main id="main-content" className="inner-page">
        <PageIntro label="Support" title="Need a hand?" description="Reach out if you have questions about subscriptions, troubleshooting, or feature requests. We're happy to help." />
        <section className="support-layout">
          <div className="support-primary">
            <p className="page-label">Direct support</p>
            <h2>Email support</h2>
            <p>Write to <a href="mailto:dealer.yen-61@icloud.com">dealer.yen-61@icloud.com</a> with as much detail as possible — what you tried, what you expected, and what happened.</p>
            <a className="arrow-button" href="mailto:dealer.yen-61@icloud.com">Email us <span aria-hidden="true">→</span></a>
          </div>
          <div className="resource-list">
            <header><h3>Quick resources</h3><p>Common destinations to help you move forward fast.</p></header>
            {resources.map(([title, description, action, href], index) => (
              <article key={title}>
                <span>{String(index + 1).padStart(2, "0")}</span>
                <div><h4>{title}</h4><p>{description}</p></div>
                {href.startsWith("http") ? <a href={href} target="_blank" rel="noreferrer">{action} <span aria-hidden="true">↗</span></a> : <Link href={href}>{action} <span aria-hidden="true">→</span></Link>}
              </article>
            ))}
          </div>
        </section>
        <section className="inline-cta">
          <div><h2>Have a <em>feature idea?</em></h2><p>We&apos;d love to hear it. Email us, or open a new request on GitHub — community input shapes the roadmap.</p></div>
          <a className="arrow-button" href="https://github.com/Joaov41/Rss/issues/new" target="_blank" rel="noreferrer">Open a request <span aria-hidden="true">↗</span></a>
        </section>
      </main>
    </SiteShell>
  );
}
