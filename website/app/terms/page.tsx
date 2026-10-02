import type { Metadata } from "next";
import { LegalDocument } from "@/components/LegalDocument";

export const metadata: Metadata = { title: "Terms of Service" };

const effectiveDate = "August 10, 2026";

export default function TermsPage() {
  return (
    <LegalDocument
      title="Terms of Service"
      effectiveDate={effectiveDate}
      description="The terms governing your use of RSSum and its connected sources and AI features."
    >
      <div className="notice">
        <p>These terms govern your use of RSSum. By using the app or its website, you agree to these terms. If you do not agree, do not use the app.</p>
      </div>

      <h2>1. The app</h2>
      <p>RSSum is a native reading application for iPhone, iPad, and Mac. It can combine RSS articles, Reddit feeds, and YouTube channels with optional summaries, Q&amp;A, text-to-speech, local models, and other reading tools. Features may change, be unavailable, or stop working with particular sources and third-party services.</p>

      <h2>2. Open-source license</h2>
      <p>The RSSum source code is available in the <a href="https://github.com/Joaov41/Rss">RSSum GitHub repository</a>. Code in that repository is subject to its applicable license. Third-party packages, models, APIs, filter lists, content, and services may have separate licenses and terms.</p>

      <h2>3. Lawful use</h2>
      <p>You are responsible for how you use RSSum and for complying with applicable law and the terms of every source or service you access. You must not use the app to:</p>
      <ul>
        <li>Access accounts, systems, content, or personal information without authorization.</li>
        <li>Distribute malware, interfere with networks or services, or evade security controls unlawfully.</li>
        <li>Copy, redistribute, or use third-party content in a way that infringes copyright, privacy, or other rights.</li>
        <li>Submit confidential or sensitive information to an external AI or speech provider without authorization.</li>
      </ul>

      <h2>4. Sources and third-party services</h2>
      <p>RSSum connects to RSS publishers, Reddit, YouTube, Apple services, AI providers, speech providers, model hosts, and optional local services that are not controlled by the developer. The developer does not endorse, control, or guarantee their availability, content, security, transactions, accuracy, or privacy practices. Your use of those services is governed by their own terms and policies.</p>
      <p>You are responsible for reviewing source content, links, permissions, forms, sign-ins, and transactions before acting on them. Content blocking, feed parsing, transcripts, reader mode, and other compatibility features may not work on every source.</p>

      <h2>5. AI and text-to-speech features</h2>
      <p>AI-generated summaries, answers, translations, analyses, and speech can be incomplete, inaccurate, biased, or misleading. They are provided for convenience and must not be treated as professional, medical, legal, financial, or safety advice. Verify important information against the original source or a qualified professional.</p>
      <p>When you select an external provider, Apple service, Shortcut, or local service, you authorize RSSum to send the prompt and the content needed for that request. You are responsible for choosing the provider, reviewing its terms, protecting its credentials, and securing any local service or network endpoint you configure.</p>

      <h2>6. Accounts and credentials</h2>
      <p>RSSum does not provide its own account system, but you may choose to connect accounts such as Reddit or an AI provider. You are responsible for your account credentials, API keys, permissions, devices, backups, and any activity performed through connected services. Do not share credentials or expose local service tokens.</p>

      <h2>7. No warranty</h2>
      <p>To the maximum extent permitted by applicable law, RSSum is provided “as is” and “as available,” without warranties of any kind. The developer does not warrant that the app or website will be uninterrupted, error-free, secure, compatible with every source, or suitable for a particular purpose. Rights that cannot lawfully be excluded remain unaffected.</p>

      <h2>8. Limitation of liability</h2>
      <p>To the maximum extent permitted by applicable law, the developer will not be liable for indirect, incidental, special, consequential, or punitive damages, or for loss of data, credentials, content, access, profits, or business arising from use of or inability to use RSSum. This limitation does not apply where liability cannot lawfully be limited.</p>

      <h2>9. Changes and availability</h2>
      <p>The app, website, connected services, or these terms may be updated, suspended, or discontinued. Continued use after revised terms are published means you accept the revised terms. The effective date above identifies the current version.</p>

      <h2>10. Contact</h2>
      <p>For questions or support, open an issue in the <a href="https://github.com/Joaov41/Rss/issues">RSSum GitHub repository</a>. GitHub issues are public, so do not post passwords, API keys, OAuth tokens, or other sensitive information.</p>
    </LegalDocument>
  );
}
