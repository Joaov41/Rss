import type { Metadata } from "next";
import { LegalDocument } from "@/components/LegalDocument";

export const metadata: Metadata = { title: "Privacy Policy" };

const effectiveDate = "August 10, 2026";

export default function PrivacyPage() {
  return (
    <LegalDocument
      title="Privacy Policy"
      effectiveDate={effectiveDate}
      description="How RSSum handles reading data, optional sync, connected sources, and AI features."
    >
      <div className="notice">
        <p><strong>The short version:</strong> RSSum does not require an account, include developer-operated advertising or analytics, or sell personal information. Your reading data is primarily stored on your devices. When you connect RSS, Reddit, YouTube, an AI provider, or an optional sync or local service, information can be sent to the service you choose so that feature can work.</p>
      </div>

      <h2>1. Scope</h2>
      <p>This policy explains how RSSum handles information in its native iPhone, iPad, and Mac apps. “RSSum,” “we,” and “us” refer to the app and its developer.</p>

      <h2>2. Information stored on your devices</h2>
      <p>RSSum stores information locally to provide reading, organization, and settings features. Depending on how you use the app, this can include:</p>
      <ul>
        <li>RSS subscriptions, Reddit subscriptions, YouTube channel subscriptions, and feed settings.</li>
        <li>Articles, Reddit posts, comments, video information, transcripts, images, and other locally cached content.</li>
        <li>Read and favorite state, saved items, app preferences, selected AI models, and voice settings.</li>
        <li>API keys, OAuth credentials, and other provider settings stored using Apple Keychain where applicable.</li>
        <li>Downloaded local language, vision, and text-to-speech models, including their local file locations.</li>
      </ul>
      <p>RSSum does not operate a user account system or maintain a hosted account database for your reading history.</p>

      <h2>3. Optional iCloud synchronization</h2>
      <p>If iCloud synchronization is available and enabled, RSSum can use Apple’s iCloud Key-Value Store to synchronize selected app state, such as subscriptions and read or favorite identifiers, between your devices. Apple’s iCloud terms and privacy policy govern Apple’s handling of that data. You can control iCloud access through your device settings.</p>

      <h2>4. RSS, Reddit, and YouTube</h2>
      <p>When you add or refresh a source, RSSum connects directly to the relevant publisher or platform. The request can include the feed, Reddit, or YouTube URL, your IP address, device and network information, and any information normally needed to make the request. The source provider’s terms and privacy policy govern its handling of that request.</p>
      <p>Reddit features may use public Reddit endpoints or optional Reddit OAuth. If you sign in to Reddit, Reddit receives and processes the authentication request under Reddit’s own policies. YouTube features can request public channel feeds, video information, captions, transcripts, and search results from YouTube.</p>

      <h2>5. AI summaries, Q&amp;A, and text-to-speech</h2>
      <p>AI features are optional and run when you choose to summarize, ask a question, analyze content, or generate speech. The information sent depends on the provider you select and may include article text, Reddit posts and comments, YouTube metadata or transcripts, your prompt, and the requested output format.</p>
      <ul>
        <li><strong>Local models:</strong> Processing occurs on your device after the model is available locally. Downloading a model can contact its hosting provider.</li>
        <li><strong>Gemini or OpenAI:</strong> RSSum sends the content and prompt needed for the selected request to the provider’s service. The provider’s terms, privacy policy, account settings, and retention practices apply.</li>
        <li><strong>Apple and other configured services:</strong> RSSum can use Apple on-device models, Apple cloud or Private Cloud Compute features, Shortcuts, or a local service you configure. The selected service determines where the request goes.</li>
        <li><strong>Text-to-speech:</strong> Text can be sent to a selected cloud speech provider, or processed locally with a supported model. System speech stays within Apple’s platform APIs.</li>
      </ul>
      <p>Review content before sending it to an external provider. Do not submit confidential information unless you understand and accept that provider’s practices.</p>

      <h2>6. Analytics, advertising, and tracking</h2>
      <p>RSSum does not include developer-operated advertising, analytics, or cross-app tracking, and the developer does not sell personal information. RSS publishers, Reddit, YouTube, AI providers, and other third-party services may use their own cookies, analytics, advertising, or tracking technologies when you connect to them.</p>

      <h2>7. Retention and deletion</h2>
      <p>Local data remains on your device until you remove it through the app or the operating system. RSSum provides controls for clearing caches and removing local content. You can also delete the app, review its files through the device’s storage controls, disable iCloud synchronization, and remove saved credentials through the relevant app or system controls.</p>
      <p>RSSum cannot delete information already sent to a publisher, Reddit, YouTube, AI provider, speech provider, Apple service, or other third party. Use that provider’s privacy and deletion controls for those requests.</p>

      <h2>8. Security</h2>
      <p>RSSum uses Apple platform storage and security features where applicable, including Keychain for selected credentials. No storage or transmission method is completely secure. Keep your devices updated, use a passcode, protect API keys, and review the destination before using an external AI or local network service.</p>

      <h2>9. Children</h2>
      <p>RSSum is a general-purpose reading application and is not directed to children under 13. The developer does not knowingly collect personal information from children through a developer-operated service.</p>

      <h2>10. Changes to this policy</h2>
      <p>This policy may change as RSSum’s features and connected services change. The effective date above will be updated when material changes are published.</p>

      <h2>11. Contact</h2>
      <p>For privacy questions, open an issue in the <a href="https://github.com/Joaov41/Rss/issues">RSSum GitHub repository</a>. GitHub issues are public, so do not include passwords, API keys, OAuth tokens, private reading history, or other sensitive information.</p>
    </LegalDocument>
  );
}
