# AI models in RSSReaderApp

RSSReaderApp can send a summary or question to several different AI paths. The important difference is not only which model is selected, but where the model runs and how much source text it can accept in one request.

## Quick choice

| Provider | Where it runs | Best use | Main limitation |
| --- | --- | --- | --- |
| Gemini | Gemini API | Long articles, Reddit threads, and Overall Summary batches | Requires a Gemini API key |
| Apple Local | On the Apple device | Private single-article or small Reddit summaries and Q&A | Small on-device context; large requests need rerouting |
| LiteRT Local | On the Apple device | Fast private local article, Reddit, comment, and Q&A work | Small context window; not available for Overall Summary batches |
| CoreAI MLX Local | On the Apple device | Comparing an MLX-format local model with LiteRT | Smaller context than LiteRT; not available for Overall Summary batches |
| Apple Cloud | Apple Intelligence through Shortcuts | Apple-managed cloud summarization | Requires the configured Shortcuts/cloud path |
| Apple PCC Gateway | Mac gateway using the `pcc` model from `fm serve` | Larger private/local-network requests, including batches | The Mac gateway must be running and reachable |
| Codex / Summarize | Mac Summarize daemon, optionally through the Mac bridge | Long summaries and Q&A using the configured Codex/Summarize path | The Mac daemon or bridge must be running |
| Web AI | ChatGPT or Gemini website in the in-app browser | The largest and most flexible web-based workflow | Requires a logged-in web session and depends on the website |

The active provider is selected in **Settings → Summary Provider**. The **Web AI Destination** setting separately chooses ChatGPT or Gemini whenever the Web AI path is used.

## Why local models work for articles and small Reddit content

Local models have a fixed context window. The context contains both the instruction and the source material, and the model also needs room for its answer. A request fails when the source plus prompt plus requested output is larger than that budget.

For a single item, the app prepares a bounded prompt:

- Articles use cleaned article text, capped by the app’s article prompt builder.
- A Reddit post includes the post and the captured comments. A long post or a deep comment tree can exceed the local budget.
- Q&A uses the relevant article or Reddit source and asks the model to answer only from that source.
- Comment summaries and local analysis also use the comments supplied by the current screen.

That is why a local model can work well for one normal article or a small Reddit post, but fail for a large Reddit discussion or a full feed.

The app treats **Overall Summary** differently. Overall Summary combines many articles or Reddit posts into one structured batch request. Apple Local, LiteRT Local, and CoreAI MLX Local are not run directly for that operation. The app presents a reroute choice and asks for a cloud, gateway, daemon, or web provider instead. This avoids silently dropping most of the feed.

If a local single-item request is too large, the app estimates the prompt size before generation when possible. If generation still reports a context error, it offers the same reroute flow. Increasing a local context setting can help only up to the model/provider limit; it cannot make an arbitrarily large Reddit thread fit.

## Using Apple PCC through the Mac gateway

The **Apple PCC Gateway** provider is a local-network gateway. RSSReaderApp does not call the `pcc` model directly from iPhone or iPad. Instead:

```text
iPhone/iPad RSSReaderApp
        │  authenticated HTTP on the local network
        ▼
Mac RSSReader PCC Gateway :1977
        │
        ▼
fm serve :1976  →  pcc model
```

The gateway exposes an OpenAI-compatible `POST /v1/chat/completions` endpoint and protects it with a bearer token. It starts `fm serve` locally on the Mac and forwards the app’s prompt to the `pcc` model. The response is returned to the app and displayed in the normal summary or Q&A UI. This is separate from **Apple Cloud**, which uses the Apple Intelligence/Shortcuts path.

### Start the gateway

On the Mac, from the RSSReaderApp checkout:

```bash
./scripts/start-fm-pcc-gateway.command
```

The script uses these defaults:

- `fm serve`: `127.0.0.1:1976`
- Gateway: `0.0.0.0:1977`
- Model: `pcc`

The script prints the Mac’s LAN IP and generates a gateway token if `PCC_GATEWAY_TOKEN` was not already set. Keep the gateway terminal running while using PCC. If the Mac does not have the `fm` command configured, the script stops and explains that Foundation Models CLI must be installed/configured first.

For a reusable Mac installation, the repository also provides:

```bash
./scripts/install-fm-pcc-gateway.command --start
```

The installer stores the generated token in a protected local environment file and creates a launcher. Treat the printed token as a secret.

### Configure RSSReaderApp

In **Settings → Summary Provider**:

1. Select **Apple PCC Gateway**.
2. Set **Mac host or IP** to `127.0.0.1` for a Mac app or Simulator. For a physical iPhone/iPad, enter the Mac’s LAN IP printed by the gateway script.
3. Set **Gateway port** to `1977`, unless the gateway was started with another port.
4. Set **Model** to `pcc`, unless `PCC_MODEL` was changed.
5. Enter the printed **Gateway token**.
6. Tap **Test Connection** and wait for **Connected**.

The iPhone/iPad and Mac must be on the same reachable network. A physical device cannot use `127.0.0.1` to reach the Mac because that address means the device itself. If the test fails, check that the gateway is still running, the host is the Mac’s current LAN IP, the port matches, and the token has no extra spaces.

Once connected, select Apple PCC Gateway and use the normal article summary, Reddit summary, comment summary, Q&A, whiteboard, or Overall Summary actions. PCC is useful when the request is too large for the device-local model, but it is still subject to the `pcc` model’s own availability and quota.

## Using Codex / Summarize

**Codex / Summarize** uses the repository’s Mac-side Summarize setup. On macOS, RSSReaderApp talks to the Summarize daemon on `127.0.0.1:8787`. On iPad, the Mac app can run a small authenticated bridge on port `8790`; that bridge forwards the prompt to the daemon and returns the result.

### Set up the Mac path

On the Mac, run:

```bash
./scripts/setup-summarize-gateway-mac.sh
```

The setup script installs/configures the Summarize CLI, creates the daemon configuration, generates or stores the daemon token and bridge secret, and records the connection details. The configured Codex path uses the `cli/codex/gpt-5.5` model with the fast service tier, low reasoning, and low verbosity. RSSReaderApp displays the local model label as `gpt-fast`.

### Use it on Mac

Select **Codex / Summarize** in Settings. The Mac app uses the daemon host and port, normally `127.0.0.1:8787`, plus the daemon token. Use **Test Connection** before trying a large summary.

### Use it from iPad

1. Keep the Mac RSSReaderApp open so its Summarize bridge is listening.
2. In the iPad app, select **Codex / Summarize**.
3. In the **Summarize Bridge** settings, enter the bridge secret/pass printed by the Mac setup.
4. Leave **Mac host or IP** empty for Bonjour/automatic discovery, or enter the Mac’s LAN IP if discovery is blocked.
5. Use bridge port `8790`, unless it was changed in the Mac setup.
6. Tap **Test Connection**.

The iPad sends the prompt to the Mac bridge, not directly to the daemon. This makes Codex/Summarize a good choice for long article batches, Reddit batches, and detailed Q&A while keeping the app’s provider selection consistent across devices.

## How Web AI works

The **Web AI** provider is a website integration, not a provider API call from RSSReaderApp. The app opens ChatGPT or Gemini in an in-app `WKWebView`, reuses the saved website session, inserts the prepared prompt, and tries to submit it automatically. The app watches the web page for the assistant response, captures the returned text, and writes it back into the normal summary or answer UI.

### First-time setup

1. In **Settings → Web AI Destination**, choose **ChatGPT** or **Gemini**.
2. Tap **Log In to ChatGPT** or **Log In to Gemini** and sign in inside RSSReaderApp.
3. Return to the app and select **Web AI** as the Summary Provider when you want the normal summarize/ask actions to use the website path.
4. Use the article, Reddit, batch summary, or Q&A action as usual.

The app keeps persistent web sessions in its WebKit data store. **Reset ChatGPT** or **Reset Gemini** clears that provider’s saved web session and requires login again.

Web AI is useful when the request needs a larger context or when the user wants to use the capabilities available in the logged-in website. The prompt still comes from the app’s current article, Reddit, or batch context; the web model is not automatically browsing for a different source. Website layout changes, login expiration, content-loading failures, or a website response that cannot be captured can cause the request to fail.

The exact underlying model is controlled by the ChatGPT or Gemini website account/session. Selecting ChatGPT or Gemini in RSSReaderApp identifies the destination website; it does not guarantee a specific model name inside that website.

## Choosing a provider by task

- **One normal article, private processing:** Apple Local, LiteRT Local, or CoreAI MLX Local.
- **One Reddit post with a manageable number of comments:** a local provider, Apple PCC Gateway, Codex / Summarize, Gemini, or Web AI.
- **Large Reddit thread or deep comment summary:** Apple PCC Gateway, Codex / Summarize, Gemini, or Web AI.
- **Overall Summary across many articles or posts:** Apple PCC Gateway, Codex / Summarize, Gemini, Apple Cloud, or Web AI.
- **A question that must be grounded in one source:** any provider, but local providers need the source to fit their context window.
- **Web-based model features:** Web AI, after logging into the selected ChatGPT or Gemini destination.

When a local request cannot fit, use the reroute prompt rather than repeatedly retrying the same local model. The reroute preserves the prepared prompt and sends it to the provider selected in the reroute choice.
