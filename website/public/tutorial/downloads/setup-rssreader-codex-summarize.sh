#!/usr/bin/env bash
set -euo pipefail

DAEMON_PORT="${DAEMON_PORT:-8787}"
BRIDGE_PORT="${BRIDGE_PORT:-8790}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.joaovalente.RSSReaderApp}"
MODEL="${MODEL:-cli/codex/gpt-5.5}"
SUMMARIZE_VERSION="${SUMMARIZE_VERSION:-0.14.1}"
SUMMARIZE_BIN="${SUMMARIZE_BIN:-}"
ENABLE_CAFFEINATE="${ENABLE_CAFFEINATE:-1}"
RUN_DIAGNOSE="${RUN_DIAGNOSE:-1}"
CONFIG_DIR="$HOME/.summarize"
CONFIG_FILE="$CONFIG_DIR/config.json"
DAEMON_FILE="$CONFIG_DIR/daemon.json"
INFO_FILE="$CONFIG_DIR/rssreader-gateway-info.txt"
KEYCHAIN_SERVICE="com.joaovalente.RSSReaderApp.summarize"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/setup-summarize-gateway-mac.sh [options]

Options:
  --daemon-token TOKEN     Use an existing Summarize daemon token.
  --bridge-secret SECRET   Use an existing RSS bridge secret/pass.
  --daemon-port PORT       Summarize daemon port. Default: 8787.
  --bridge-port PORT       RSS bridge port. Default: 8790.
  --bundle-id ID           RSS app bundle id. Default: com.joaovalente.RSSReaderApp.
  --no-caffeinate          Do not start keep-awake.
  --no-diagnose            Skip the direct summary test.
  --help                   Show this help.

Environment overrides:
  APP_BUNDLE_ID, DAEMON_PORT, BRIDGE_PORT, MODEL, SUMMARIZE_VERSION,
  SUMMARIZE_BIN, ENABLE_CAFFEINATE, RUN_DIAGNOSE
EOF
}

DAEMON_TOKEN="${DAEMON_TOKEN:-}"
BRIDGE_SECRET="${BRIDGE_SECRET:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --daemon-token)
      DAEMON_TOKEN="${2:-}"
      shift 2
      ;;
    --bridge-secret)
      BRIDGE_SECRET="${2:-}"
      shift 2
      ;;
    --daemon-port)
      DAEMON_PORT="${2:-}"
      shift 2
      ;;
    --bridge-port)
      BRIDGE_PORT="${2:-}"
      shift 2
      ;;
    --bundle-id)
      APP_BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --no-caffeinate)
      ENABLE_CAFFEINATE=0
      shift
      ;;
    --no-diagnose)
      RUN_DIAGNOSE=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

require_command() {
  local command_name="$1"
  local install_hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name"
    echo "$install_hint"
    exit 1
  fi
}

validate_port() {
  local value="$1"
  local name="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    echo "$name must be a number from 1 to 65535. Got: $value"
    exit 1
  fi
}

random_hex() {
  local bytes="$1"
  openssl rand -hex "$bytes"
}

local_ip() {
  local ip=""
  ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(ipconfig getifaddr en1 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\\./ { print $2; exit }' || true)"
  fi
  printf '%s' "$ip"
}

write_keychain_secret() {
  local account="$1"
  local value="$2"
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1 || true
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$account" -w "$value" >/dev/null
}

write_rss_defaults() {
  defaults write "$APP_BUNDLE_ID" summarizeDaemonToken "$DAEMON_TOKEN"
  defaults write "$APP_BUNDLE_ID" macBridgeSecret "$BRIDGE_SECRET"
  defaults write "$APP_BUNDLE_ID" macBridgeHost "127.0.0.1"
  defaults write "$APP_BUNDLE_ID" macBridgePort -int "$BRIDGE_PORT"
  defaults write "$APP_BUNDLE_ID" summarizeDaemonHost "127.0.0.1"
  defaults write "$APP_BUNDLE_ID" summarizeDaemonPort -int "$DAEMON_PORT"
  defaults write "$APP_BUNDLE_ID" summarizeDaemonModel "gpt-fast"

  write_keychain_secret "summarize_daemon_token" "$DAEMON_TOKEN"
  write_keychain_secret "summarize_bridge_secret" "$BRIDGE_SECRET"
}

echo "RSS Codex / Summarize gateway setup"
echo

validate_port "$DAEMON_PORT" "Daemon port"
validate_port "$BRIDGE_PORT" "Bridge port"
require_command openssl "Install OpenSSL or use the macOS-provided openssl."
require_command npm "Install Node.js from https://nodejs.org/ before running this script."
require_command security "The macOS security command is required to prefill keychain secrets."

if ! command -v codex >/dev/null 2>&1; then
  echo "Codex is not on PATH."
  echo "Install Codex and run 'codex login', then rerun this script."
  exit 1
fi

if [[ -z "$DAEMON_TOKEN" ]]; then
  DAEMON_TOKEN="$(random_hex 24)"
fi

if [[ -z "$BRIDGE_SECRET" ]]; then
  BRIDGE_SECRET="$(random_hex 18)"
fi

echo "Installing Summarize CLI @steipete/summarize@$SUMMARIZE_VERSION..."
npm install -g "@steipete/summarize@$SUMMARIZE_VERSION"

if [[ -z "$SUMMARIZE_BIN" ]]; then
  SUMMARIZE_BIN="$(npm prefix -g)/bin/summarize"
fi

if [[ ! -x "$SUMMARIZE_BIN" ]]; then
  echo "Summarize binary was not found at: $SUMMARIZE_BIN"
  exit 1
fi

mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
{
  "model": "$MODEL",
  "cli": {
    "codex": {
      "extraArgs": [
        "-c",
        "service_tier=\"fast\"",
        "-c",
        "model_reasoning_effort=\"low\"",
        "-c",
        "text.verbosity=\"low\""
      ]
    }
  },
  "output": {
    "length": "short"
  }
}
EOF

cat > "$DAEMON_FILE" <<EOF
{
  "host": "127.0.0.1",
  "port": $DAEMON_PORT,
  "token": "$DAEMON_TOKEN"
}
EOF

echo "Installing Summarize daemon on 127.0.0.1:$DAEMON_PORT..."
"$SUMMARIZE_BIN" daemon install --port "$DAEMON_PORT" --token "$DAEMON_TOKEN"
"$SUMMARIZE_BIN" daemon restart

echo "Prefilling RSS settings for bundle id: $APP_BUNDLE_ID"
write_rss_defaults

if [[ "$ENABLE_CAFFEINATE" == "1" ]]; then
  PID_FILE="$HOME/.rssreader-gateway-caffeinate.pid"
  if [[ -f "$PID_FILE" ]]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${OLD_PID:-}" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "Keep-awake is already running with PID $OLD_PID."
    else
      rm -f "$PID_FILE"
    fi
  fi
  if [[ ! -f "$PID_FILE" ]]; then
    /usr/bin/caffeinate -dimsu &
    echo "$!" > "$PID_FILE"
    echo "Keep-awake started. PID file: $PID_FILE"
  fi
fi

MAC_IP="$(local_ip)"

cat > "$INFO_FILE" <<EOF
RSS Codex / Summarize gateway

Mac host/IP for iPad:
$MAC_IP

Use this only if automatic bridge discovery does not connect.
The Mac IP can change when the Mac changes networks or renews Wi-Fi.

Bridge port:
$BRIDGE_PORT

Bridge secret/pass:
$BRIDGE_SECRET

Mac-only daemon settings:
Daemon host: 127.0.0.1
Daemon port: $DAEMON_PORT
Daemon token: $DAEMON_TOKEN
Model: gpt-fast ($MODEL)

Next steps:
1. Install/open RSS on this Mac.
2. Keep RSS open so the bridge can listen on port $BRIDGE_PORT.
3. On iPad RSS, choose Codex / Summarize.
4. On iPad RSS, leave Mac host/IP blank for automatic discovery, or set it to $MAC_IP if discovery is blocked.
5. On iPad RSS, set bridge port to $BRIDGE_PORT.
6. On iPad RSS, set bridge secret/pass to the value above.
7. Tap Test Connection.
EOF

echo
echo "Checking daemon status..."
"$SUMMARIZE_BIN" daemon status || true
lsof -nP -iTCP:"$DAEMON_PORT" -sTCP:LISTEN || true

if [[ "$RUN_DIAGNOSE" == "1" ]]; then
  echo
  echo "Running a direct summary test..."
  "$SUMMARIZE_BIN" "https://example.com" --length short --timeout 45s --verbose || true
fi

echo
echo "Gateway setup complete."
echo
echo "Use these iPad settings:"
echo "Mac host/IP: leave blank for automatic discovery; fallback current Mac IP is ${MAC_IP:-Unable to detect; check System Settings > Wi-Fi > Details}"
echo "Bridge port: $BRIDGE_PORT"
echo "Bridge secret/pass: $BRIDGE_SECRET"
echo
echo "Saved the full setup info at:"
echo "$INFO_FILE"
echo
echo "Important: install/open RSS on this Mac and keep it open. The Summarize daemon is running now, but RSS provides the iPad bridge."
