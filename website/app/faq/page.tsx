import type { Metadata } from "next";
import Link from "next/link";
import { PageIntro } from "@/components/PageIntro";
import { SiteShell } from "@/components/SiteShell";

export const metadata: Metadata = { title: "FAQ" };

const faqs = [
  ["Is RSSum free?", <>Yes! RSSum is open source and always free to use.</>],
  ["Does it work offline?", <>Your saved feeds and articles are stored on your device and are available offline. On-device AI models can process supported content locally. Optional cloud providers need an internet connection and receive the content you send for summarization or Q&A.</>],
  ["How does the AI Q&A work?", <>Ask questions about RSS articles, Reddit discussions, YouTube videos, or podcast episodes. Choose your AI provider in Settings. Local models, cloud APIs, and Mac gateway options are explained in the <a href="/tutorial/index.html#models">model guide</a>.</>],
  ["How does Reddit access work?", <>Create an <strong>installed app</strong> in Reddit&apos;s developer settings and set its redirect URI to exactly <code>redapp://auth</code>. Paste the app&apos;s Client ID into RSSum, not a client secret, and make sure there is no trailing slash or whitespace. <a href="/tutorial/index.html#reddit-setup">See the Reddit setup guide</a>.</>],
  ["Where can I report bugs or request features?", <>Open an issue or feature request on our GitHub repo. We&apos;re community-driven and welcome your input. <a href="https://github.com/Joaov41/Rss/issues" target="_blank" rel="noreferrer">Open GitHub issues</a></>],
  ["Can I contribute?", <>Absolutely! We welcome contributions. Check out our GitHub for details on how to get started. <a href="https://github.com/Joaov41/Rss" target="_blank" rel="noreferrer">Visit the repository</a></>],
  ["Which platforms are supported?", <>RSSum is a native app for macOS, iPadOS, and iOS — built to feel at home on every Apple device.</>],
] as const;

export default function FAQPage() {
  return (
    <SiteShell>
      <main id="main-content" className="inner-page">
        <PageIntro label="FAQ" title="Frequently asked questions" description="Everything you might want to know about RSSum, AI summaries, privacy, and how to get started." />
        <section className="faq-list">
          {faqs.map(([question, answer], index) => (
            <details key={question} open={index === 0}>
              <summary><span>{String(index + 1).padStart(2, "0")}</span><strong>{question}</strong><i aria-hidden="true">+</i></summary>
              <div><p>{answer}</p></div>
            </details>
          ))}
        </section>
        <section className="inline-cta">
          <div><h2>Still have <em>questions?</em></h2><p>Reach out — we usually reply within 1–2 business days.</p></div>
          <Link className="arrow-button" href="/support">Contact support <span aria-hidden="true">→</span></Link>
        </section>
      </main>
    </SiteShell>
  );
}
