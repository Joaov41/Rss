import type { Metadata } from "next";
import { ArrowUpRight } from "lucide-react";
import { PageIntro } from "@/components/PageIntro";
import { SiteShell } from "@/components/SiteShell";
import { APPSTORE_URL, GITHUB_URL, TESTFLIGHT_URL } from "@/components/links";

export const metadata: Metadata = { title: "Download" };

const downloads = [
  { device: "iPhone", platform: "iPhone", description: "Your full timeline, summaries and questions on your phone. Good for catching up on podcasts and long threads." },
  { device: "iPad", platform: "iPad", description: "The layout you see in most screenshots here: subscriptions on the left, reading on the right. Supports keyboards and Stage Manager." },
  { device: "Mac", platform: "Mac", description: "A native build for Apple Silicon Macs, with the same reader and AI features as on iPad." },
] as const;

export default function DownloadPage() {
  return (
    <SiteShell>
      <main id="main-content" className="inner-page">
        <PageIntro label="Download" title="Get RSSum" description="Free on the App Store. Want new features before they ship? Join the TestFlight beta." />
        <section className="download-list">
          {downloads.map(({ device, platform, description }, index) => (
            <article key={device}>
              <span>{String(index + 1).padStart(2, "0")}</span>
              <p className="device-label">{device}</p>
              <div><h2>{platform}</h2><p>{description}</p></div>
              <div className="download-links">
                <a className="arrow-button" href={APPSTORE_URL} target="_blank" rel="noreferrer">App Store<ArrowUpRight size={18} aria-hidden="true" /></a>
                <a className="text-link" href={TESTFLIGHT_URL} target="_blank" rel="noreferrer">TestFlight beta<ArrowUpRight size={17} aria-hidden="true" /></a>
              </div>
            </article>
          ))}
        </section>
        <p className="source-note">The source code is on <a href={GITHUB_URL} target="_blank" rel="noreferrer">GitHub</a> if you want to build it yourself.</p>
      </main>
    </SiteShell>
  );
}
