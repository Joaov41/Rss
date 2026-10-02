import type { Metadata } from "next";
import "./globals.css";
import "./showcase.css";
import "./theme-light.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://www.rssapp.top"),
  title: {
    default: "RSSum | RSS, Reddit, YouTube & Podcasts",
    template: "%s | RSSum",
  },
  description:
    "Read RSS articles, follow Reddit and YouTube, and listen to podcasts. Summarize and ask questions with RSSum for Mac, iPad, and iPhone.",
  icons: { icon: "/favicon.png", apple: "/app-icon.png" },
  openGraph: {
    type: "website",
    title: "RSSum | RSS, Reddit, YouTube & Podcasts",
    description:
      "RSS articles, Reddit, YouTube, and podcasts in one native app, with summarization and Q&A.",
    url: "https://www.rssapp.top",
    siteName: "RSSum",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" data-scroll-behavior="smooth">
      <body>{children}</body>
    </html>
  );
}
