import type { Metadata } from "next";
import Link from "next/link";
import { PageIntro } from "@/components/PageIntro";
import { Reveal } from "@/components/Reveal";
import { SiteShell } from "@/components/SiteShell";

export const metadata: Metadata = { title: "Features" };

const features = [
  ["AI Summarization", "Instantly condense lengthy articles, Reddit posts, podcast episodes, and YouTube videos into clear, actionable summaries. Save time and stay informed at a glance. For Reddit, it summarizes ALL comments — not just a few like most alternatives. A real engineering challenge we're proud of."],
  ["Interactive Q&A", "Ask any question about an article, Reddit post, podcast episode, or YouTube video and get instant, AI-powered answers. Uncover key points, explanations, or related facts effortlessly — as if you were chatting with the author. If a podcast does not provide a transcript, RSSum creates one locally."],
  ["Unified Feed Experience", "Combine RSS feeds, Reddit subscriptions, podcast feeds, and YouTube channels in one distraction-free timeline. Organize, favorite, and mark items as you like — your sources, your rules."],
  ["Privacy & Local Storage", "All your Feed data stays on your device. RSSum never tracks, syncs, or shares your reading habits. What you read is yours alone."],
  ["On-Device AI Models", "Prefer to stay fully offline? RSSum supports Apple's on-device models so you can summarize and ask questions without sending anything anywhere."],
  ["Text to Speech", "Listen to your feeds on the go. TTS powered by the OpenAI API or fully local voices — system voices or local MLX TTS with natural-sounding voices. Your call, your commute."],
  ["Local Podcast Creation", "Turn articles and saved reading into podcast-style episodes directly on your device. Generate and listen with local voices for a private, offline-friendly listening experience."],
  ["Embedded Podcast Player", "Play podcast episodes directly inside RSSum while you read, summarize, and ask questions — no app switching required."],
  ["Deep Reddit Analysis", "Surface the signal from the noise across long comment chains. RSSum reads deep threads so you don't have to."],
  ["Your Reddit Account, Your Access", "Connect your Reddit account and RSSum uses the free Reddit Data API access associated with that account through OAuth. There is no shared paid Reddit service; Reddit's eligibility rules and rate limits still apply."],
  ["Live Activities & True Background", "Your feeds keep updating even when the app is closed. Live Activities surface fresh content on the Lock Screen and Dynamic Island, while the True Background API keeps subscriptions syncing in the background — so you're always up to date the moment you open RSSum."],
  ["Open Source & Extensible", "Fork, contribute, or customize RSSum for your workflow. Community-driven and free on GitHub — built in the open."],
  ["A Model for Every Mind", "Choose the brain that fits the moment. Apple's on-device model keeps everything private and instant. Run Gemini 4 locally through Core AI MLX or LiteRT for heavyweight on-device reasoning, or lean on Web AI for browser-grade inference. Route the big workloads through Apple's Private Cloud Compute, with your Mac acting as the gateway — and Codex subscribers can plug in their own accounts the same way. One reading experience, an entire constellation of models."],
  ["Free models, built in", "ChatGPT and Gemini join the roster through their web interfaces, with support for free accounts. Choose the service you want to use and ask questions directly from your reading workflow."],
] as const;

export default function FeaturesPage() {
  return (
    <SiteShell>
      <main id="main-content" className="inner-page">
        <PageIntro label="Features" title="Everything RSSum does for you" description="Discover what makes RSSum a powerful feed reader for Mac, iPad, and iPhone — AI-native, privacy-first, and built for serious readers." />
        <section className="feature-index" aria-label="RSSum features">
          {features.map(([title, description], index) => (
            <Reveal key={title} as="div">
              <article>
                <span>{String(index + 1).padStart(2, "0")}</span>
                <h2>{title}</h2>
                <p>{description}</p>
              </article>
            </Reveal>
          ))}
        </section>
        <Reveal>
          <section className="inline-cta">
            <div><h2>Want to <em>try it?</em></h2><p>Download RSSum and put these features to work today.</p></div>
            <Link className="arrow-button" href="/download">Get the App <span aria-hidden="true">→</span></Link>
          </section>
        </Reveal>
      </main>
    </SiteShell>
  );
}
