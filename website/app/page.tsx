import Link from "next/link";
import Image from "next/image";
import { ArrowRight, ArrowUpRight } from "lucide-react";
import { Gallery } from "@/components/Gallery";
import { SourceStories } from "@/components/SourceStories";
import { SiteShell } from "@/components/SiteShell";
import { APPSTORE_URL, GITHUB_URL, TESTFLIGHT_URL } from "@/components/links";
import "./cinematic.css";
import "./redesign.css";

const features = [
  ["Summaries of the whole thread", "Reddit summaries cover the comments, not only the post. Articles, videos and podcast episodes get the same treatment."],
  ["Questions across feeds", "Ask about one article, a whole subscription, or what several of your feeds have in common."],
  ["Transcripts made on device", "If a podcast episode has no transcript, RSSum creates one locally, then summarizes it."],
  ["Your reading as a podcast", "Turn saved summaries into a two-host episode with local voices. It works offline."],
  ["Read aloud", "Listen to articles and summaries with local voices or the OpenAI API."],
  ["Your choice of model", "Apple's on-device models, or the AI provider you already use."],
] as const;

const questions = [
  "What's actually new in this announcement?",
  "Where do the top commenters disagree?",
  "What did this week's episodes say about pricing?",
];

export default function Home() {
  return (
    <SiteShell>
      <main id="main-content" className="home-page redesign">
        <section className="rd-hero rd-wrap" aria-labelledby="hero-title">
          <p className="rd-kicker">RSSum is a feed reader for Mac, iPad and iPhone.</p>
          <h1 id="hero-title">One reader for <a href="#source-rss">RSS</a>, <a href="#source-reddit">Reddit</a>, <a href="#source-youtube">YouTube</a> and <a href="#source-podcasts">podcasts</a>.</h1>
          <div className="rd-hero-foot">
            <p>Summarize a long article, a busy Reddit thread or an hour-long episode, then ask follow-up questions. Use Apple&apos;s on-device models or connect your own AI provider.</p>
            <div className="rd-actions">
              <a className="arrow-button" href={APPSTORE_URL} target="_blank" rel="noreferrer">Download on the App Store <ArrowUpRight size={18} aria-hidden="true" /></a>
              <span>Free. Or <a href={TESTFLIGHT_URL} target="_blank" rel="noreferrer">join the TestFlight beta</a>.</span>
            </div>
          </div>
          <figure className="rd-hero-shot">
            <div className="device-frame"><Image src="/hero-services.png" alt="RSSum All Articles view with RSS and Reddit subscriptions in the sidebar" width={2360} height={1640} priority sizes="(max-width: 760px) 94vw, 1200px" /></div>
            <figcaption>All Articles on iPad, with RSS and Reddit subscriptions in the sidebar. <a href="#walkthrough">Watch the one-minute film</a></figcaption>
          </figure>
        </section>

        <section className="rd-section rd-wrap" id="sources" aria-labelledby="sources-title">
          <header className="rd-head">
            <h2 id="sources-title">Follow anything with a feed.</h2>
            <p>Each source gets its own reader. Summaries and questions work the same way in all four.</p>
          </header>
          <SourceStories />
        </section>

        <section className="rd-section rd-wrap rd-ask" id="features" aria-labelledby="ask-title">
          <div>
            <h2 id="ask-title">Ask about what you&apos;re reading.</h2>
            <p>Answers come from the article, thread or episode in front of you, so you can check them against the original right away. For example:</p>
            <ul className="rd-questions">
              {questions.map(question => <li key={question}>{question}</li>)}
            </ul>
          </div>
          <figure>
            <a className="device-frame" href="/gallery/set-20260825-1639/gallery-03.png" target="_blank" rel="noreferrer" aria-label="Open article Q&A screenshot full size"><Image src="/gallery/set-20260825-1639/gallery-03.png" alt="A summary of an Ars Technica article with the Ask a question field below it" width={2360} height={1640} sizes="(max-width: 760px) 92vw, 760px" /></a>
            <figcaption>Summary and question field for an Ars Technica article.</figcaption>
          </figure>
        </section>

        <section className="rd-section rd-wrap" aria-labelledby="more-title">
          <header className="rd-head">
            <h2 id="more-title">Also in the app</h2>
            <Link className="text-link" href="/features">Full feature list <ArrowRight size={17} aria-hidden="true" /></Link>
          </header>
          <dl className="rd-list">
            {features.map(([term, detail]) => <div key={term}><dt>{term}</dt><dd>{detail}</dd></div>)}
          </dl>
        </section>

        <section className="rd-privacy" aria-labelledby="privacy-title">
          <div className="rd-wrap">
            <h2 id="privacy-title">Your feeds stay on your device.</h2>
            <p>No tracking and no telemetry. With Apple&apos;s on-device models and local voices, nothing you read leaves your device. If you choose a cloud service instead, such as your own AI provider or OpenAI for read-aloud, the text you summarize, ask about or listen to is sent to that service. The code is <a href={GITHUB_URL} target="_blank" rel="noreferrer">on GitHub</a> if you want to check.</p>
          </div>
        </section>

        <section className="rd-section rd-wrap" id="walkthrough" aria-labelledby="walkthrough-title">
          <header className="rd-head"><h2 id="walkthrough-title">See it in use</h2><Link className="text-link" href="/tutorial/">Step-by-step tutorial <ArrowUpRight size={17} aria-hidden="true" /></Link></header>
          <figure className="closing-video"><video controls playsInline preload="metadata" poster="/RSSum-product-film-poster-v2.jpg" aria-label="RSSum product film"><source src="/RSSum-product-film-v2.mp4" type="video/mp4" />Your browser does not support HTML video.</video></figure>
        </section>

        <section className="rd-section rd-wrap" id="gallery" aria-labelledby="gallery-title">
          <header className="rd-head"><h2 id="gallery-title">Screens from the app</h2><p>Twenty screenshots from RSSum on iPad and Mac.</p></header>
          <Gallery />
        </section>

        <section className="rd-section rd-wrap" aria-labelledby="start-title">
          <header className="rd-head"><h2 id="start-title">Getting started</h2><Link className="text-link" href="/tutorial/">Setup guide <ArrowRight size={17} aria-hidden="true" /></Link></header>
          <ol className="rd-steps">
            <li><strong>Add your sources.</strong> Browse in the app and subscribe to feeds, subreddits, YouTube channels and podcasts.</li>
            <li><strong>Pick an AI provider.</strong> Apple&apos;s on-device models, or an API key for the provider you prefer.</li>
            <li><strong>Read, watch or listen.</strong> Open anything in your timeline and tap Summary for the short version.</li>
            <li><strong>Ask and save.</strong> Ask follow-up questions, and favorite what you want to come back to.</li>
          </ol>
        </section>

        <section className="rd-close rd-wrap" aria-labelledby="close-title">
          <h2 id="close-title">Get RSSum. It&apos;s free.</h2>
          <div className="rd-actions">
            <a className="arrow-button" href={APPSTORE_URL} target="_blank" rel="noreferrer">Download on the App Store <ArrowUpRight size={18} aria-hidden="true" /></a>
            <span>Or <a href={TESTFLIGHT_URL} target="_blank" rel="noreferrer">join the TestFlight beta</a>.</span>
          </div>
        </section>
      </main>
    </SiteShell>
  );
}
