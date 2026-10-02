#!/bin/zsh
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.rssreader-pcc-gateway}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
APP_DIR="${APP_DIR:-$HOME/Applications/RSSReader PCC Gateway}"
DESKTOP_LAUNCHER="${DESKTOP_LAUNCHER:-$HOME/Desktop/Start-RSSReader-PCC-Gateway.command}"
TOKEN="${PCC_GATEWAY_TOKEN:-}"
PORT="${PCC_GATEWAY_PORT:-1977}"
FM_PORT="${FM_PORT:-1976}"
MODEL="${PCC_MODEL:-pcc}"
START_NOW=0

usage() {
  cat <<EOF
Install RSSReaderApp Apple PCC Gateway on this Mac.

Usage:
  ./scripts/install-fm-pcc-gateway.command [options]

Options:
  --token <token>     Reuse a specific gateway token.
  --port <port>       Gateway port. Default: 1977.
  --fm-port <port>    Local fm serve port. Default: 1976.
  --model <model>     Gateway model. Default: pcc.
  --start             Start the gateway after installing.
  --help              Show this help.

This installer is self-contained. You can copy just this file to another Mac.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --fm-port)
      FM_PORT="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --start)
      START_NOW=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

script_dir="${0:A:h}"
source_start_script="$script_dir/start-fm-pcc-gateway.command"

if [[ ! -f "$source_start_script" ]]; then
  embedded_start_script="$(mktemp -t rssreader-pcc-start.XXXXXX)"
  awk '
    /^__RSSREADER_PCC_GATEWAY_START_SCRIPT__$/ { found=1; next }
    found { print }
  ' "$0" > "$embedded_start_script"
  if [[ ! -s "$embedded_start_script" ]]; then
    echo "Error: embedded gateway starter script is missing from this installer."
    echo "Expected a sibling script at: $source_start_script"
    exit 1
  fi
  source_start_script="$embedded_start_script"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this installer is for macOS."
  exit 1
fi

for required in python3 osascript ipconfig; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "Error: required command not found: $required"
    exit 1
  fi
done

if ! command -v fm >/dev/null 2>&1; then
  echo "Error: fm command not found."
  echo "Install/configure the Apple Foundation Models CLI from the same beta toolchain first."
  exit 1
fi

case "$PORT" in
  ''|*[!0-9]*)
    echo "Error: --port must be a number."
    exit 1
    ;;
esac

case "$FM_PORT" in
  ''|*[!0-9]*)
    echo "Error: --fm-port must be a number."
    exit 1
    ;;
esac

if [[ -z "$TOKEN" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    TOKEN="$(openssl rand -hex 24)"
  else
    TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  fi
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$APP_DIR"
cp "$source_start_script" "$INSTALL_DIR/start-fm-pcc-gateway.command"
chmod +x "$INSTALL_DIR/start-fm-pcc-gateway.command"

cat > "$INSTALL_DIR/env" <<EOF
PCC_GATEWAY_TOKEN='$TOKEN'
PCC_GATEWAY_PORT='$PORT'
FM_PORT='$FM_PORT'
PCC_MODEL='$MODEL'
PCC_DIRECT_FALLBACK='1'
EOF
chmod 600 "$INSTALL_DIR/env"

cat > "$BIN_DIR/rssreader-pcc-gateway" <<EOF
#!/bin/zsh
set -euo pipefail
source "$INSTALL_DIR/env"
exec "$INSTALL_DIR/start-fm-pcc-gateway.command"
EOF
chmod +x "$BIN_DIR/rssreader-pcc-gateway"

cat > "$APP_DIR/Start RSSReader PCC Gateway.command" <<EOF
#!/bin/zsh
set -euo pipefail
source "$INSTALL_DIR/env"
exec "$INSTALL_DIR/start-fm-pcc-gateway.command"
EOF
chmod +x "$APP_DIR/Start RSSReader PCC Gateway.command"

if [[ -d "$HOME/Desktop" ]]; then
  cat > "$DESKTOP_LAUNCHER" <<EOF
#!/bin/zsh
set -euo pipefail
source "$INSTALL_DIR/env"
exec "$INSTALL_DIR/start-fm-pcc-gateway.command"
EOF
  chmod +x "$DESKTOP_LAUNCHER"
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "YOUR_MAC_IP")"

echo ""
echo "RSSReaderApp Apple PCC Gateway installed."
echo ""
echo "Installed files:"
echo "  $INSTALL_DIR/start-fm-pcc-gateway.command"
echo "  $INSTALL_DIR/env"
echo "  $BIN_DIR/rssreader-pcc-gateway"
echo "  $APP_DIR/Start RSSReader PCC Gateway.command"
if [[ -f "$DESKTOP_LAUNCHER" ]]; then
  echo "  $DESKTOP_LAUNCHER"
fi
echo ""
echo "Run it with either:"
if [[ -f "$DESKTOP_LAUNCHER" ]]; then
  echo "  open '$DESKTOP_LAUNCHER'"
fi
echo "  open '$APP_DIR/Start RSSReader PCC Gateway.command'"
echo "  $BIN_DIR/rssreader-pcc-gateway"
echo ""
echo "RSSReaderApp iPad settings:"
echo "  Host: $LAN_IP"
echo "  Port: $PORT"
echo "  Token: $TOKEN"
echo "  Model: $MODEL"
echo ""
echo "Local health test after starting:"
echo "  curl -H 'Authorization: Bearer $TOKEN' http://127.0.0.1:$PORT/health"
echo ""

echo "Checking fm availability from this shell:"
fm available || true
fm quota-usage -m pcc || true

if [[ "$START_NOW" == "1" ]]; then
  echo ""
  echo "Starting gateway in Terminal..."
  osascript -e "tell application \"Terminal\" to do script \"$BIN_DIR/rssreader-pcc-gateway\""
fi

exit 0
__RSSREADER_PCC_GATEWAY_START_SCRIPT__
#!/bin/zsh
set -euo pipefail

FM_HOST="${FM_HOST:-127.0.0.1}"
FM_PORT="${FM_PORT:-1976}"
GATEWAY_HOST="${GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${GATEWAY_PORT:-1977}"
PCC_MODEL="${PCC_MODEL:-pcc}"

if [[ -z "${PCC_GATEWAY_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    PCC_GATEWAY_TOKEN="$(openssl rand -hex 24)"
  else
    PCC_GATEWAY_TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  fi
fi

if ! command -v fm >/dev/null 2>&1; then
  echo "Error: fm command not found. Install/configure Foundation Models CLI first."
  exit 1
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "YOUR_MAC_IP")"
FM_BASE_URL="http://${FM_HOST}:${FM_PORT}"

cleanup() {
  if [[ -n "${FM_PID:-}" ]]; then
    kill "${FM_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting fm serve on ${FM_BASE_URL} with model ${PCC_MODEL}..."
fm serve --host "${FM_HOST}" --port "${FM_PORT}" &
FM_PID="$!"

echo ""
echo "Apple PCC Gateway"
echo "URL for Simulator/Mac: http://127.0.0.1:${GATEWAY_PORT}"
echo "URL for iPhone/iPad:  http://${LAN_IP}:${GATEWAY_PORT}"
echo "Token: ${PCC_GATEWAY_TOKEN}"
echo ""
echo "In RSSReaderApp Settings -> Summary Provider -> Apple PCC Gateway:"
echo "  Host: ${LAN_IP} (or 127.0.0.1 in Simulator)"
echo "  Port: ${GATEWAY_PORT}"
echo "  Token: ${PCC_GATEWAY_TOKEN}"
echo "  Model: ${PCC_MODEL}"
echo ""
echo "Health test:"
echo "  curl -H 'Authorization: Bearer ${PCC_GATEWAY_TOKEN}' http://127.0.0.1:${GATEWAY_PORT}/health"
echo ""

PCC_GATEWAY_TOKEN="${PCC_GATEWAY_TOKEN}" \
PCC_GATEWAY_HOST="${GATEWAY_HOST}" \
PCC_GATEWAY_PORT="${GATEWAY_PORT}" \
PCC_MODEL="${PCC_MODEL}" \
FM_BASE_URL="${FM_BASE_URL}" \
python3 -u <<'PY'
import json
import os
import re
import shlex
import subprocess
import time
import uuid
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ["PCC_GATEWAY_TOKEN"]
HOST = os.environ["PCC_GATEWAY_HOST"]
PORT = int(os.environ["PCC_GATEWAY_PORT"])
MODEL = os.environ["PCC_MODEL"]
FM_BASE_URL = os.environ["FM_BASE_URL"].rstrip("/")
DIRECT_FALLBACK = os.environ.get("PCC_DIRECT_FALLBACK", "1") != "0"
ANSI_PATTERN = re.compile(r"\x1b\[[0-9;]*m")


def json_bytes(payload):
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def strip_ansi(text):
    return ANSI_PATTERN.sub("", text or "").strip()


def applescript_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def run_in_terminal_shell(command, timeout=300):
    run_id = uuid.uuid4().hex
    output_path = f"/tmp/rssreader-pcc-{run_id}.out"
    status_path = f"/tmp/rssreader-pcc-{run_id}.status"
    terminal_command = (
        f"{command} > {shlex.quote(output_path)} 2>&1; "
        f"printf '%s' $? > {shlex.quote(status_path)}; exit"
    )
    script = f'tell application "Terminal" to do script {applescript_string(terminal_command)}'

    subprocess.run(
        ["osascript", "-e", script],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=True,
    )

    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(status_path):
            with open(status_path, "r", encoding="utf-8", errors="replace") as status_file:
                raw_status = status_file.read().strip()
            with open(output_path, "r", encoding="utf-8", errors="replace") as output_file:
                output = strip_ansi(output_file.read())
            try:
                status = int(raw_status)
            except ValueError:
                status = 1
            for path in (output_path, status_path):
                try:
                    os.remove(path)
                except OSError:
                    pass
            return status, output
        time.sleep(0.25)

    raise TimeoutError("Timed out waiting for Terminal fm command.")


def message_content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                text = item.get("text") or item.get("content")
                if isinstance(text, str):
                    parts.append(text)
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(parts)
    return ""


def messages_to_prompt(messages):
    lines = []
    for message in messages if isinstance(messages, list) else []:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "user").upper()
        text = message_content_text(message.get("content")).strip()
        if text:
            lines.append(f"{role}:\n{text}")
    return "\n\n".join(lines).strip()


def direct_pcc_available():
    if MODEL != "pcc" or not DIRECT_FALLBACK:
        return False
    try:
        status, output = run_in_terminal_shell("fm available --model pcc", timeout=30)
        return status == 0 and "available" in output.lower()
    except Exception:
        return False


def direct_pcc_response(prompt):
    prompt_path = f"/tmp/rssreader-pcc-{uuid.uuid4().hex}.prompt"
    with open(prompt_path, "w", encoding="utf-8") as prompt_file:
        prompt_file.write(prompt)
    command = f'fm respond --model pcc "$(cat {shlex.quote(prompt_path)})"'
    try:
        status, output = run_in_terminal_shell(command, timeout=300)
    finally:
        try:
            os.remove(prompt_path)
        except OSError:
            pass
    if status != 0:
        raise RuntimeError(output or f"fm respond exited with status {status}")
    if not output:
        raise RuntimeError("fm respond returned an empty response.")
    return output


def openai_chat_response(text):
    now = int(time.time())
    return {
        "id": "chatcmpl-" + uuid.uuid4().hex,
        "object": "chat.completion",
        "created": now,
        "model": MODEL,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": text},
            "finish_reason": "stop"
        }]
    }


class GatewayHandler(BaseHTTPRequestHandler):
    server_version = "RSSReaderPCCGateway/1.0"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args))

    def _send_json(self, status, payload):
        body = json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        expected = "Bearer " + TOKEN
        supplied = self.headers.get("Authorization", "")
        if supplied != expected:
            self._send_json(401, {
                "error": {
                    "type": "unauthorized",
                    "message": "Missing or invalid Apple PCC Gateway token."
                }
            })
            return False
        return True

    def do_GET(self):
        if self.path != "/health":
            self._send_json(404, {"error": {"type": "not_found", "message": "Unknown endpoint."}})
            return
        if not self._authorized():
            return

        fm_status = "ok"
        fm_body = None
        pcc_available = None
        try:
            with urllib.request.urlopen(FM_BASE_URL + "/health", timeout=5) as response:
                fm_body = response.read().decode("utf-8", errors="replace")
                try:
                    fm_json = json.loads(fm_body)
                    for model in fm_json.get("models", []):
                        if model.get("name") == MODEL:
                            pcc_available = bool(model.get("available"))
                            if not pcc_available:
                                fm_status = "pcc_unavailable"
                            break
                except Exception:
                    pass
        except urllib.error.HTTPError as exc:
            fm_status = "error"
            fm_body = exc.read().decode("utf-8", errors="replace")
        except Exception as exc:
            fm_status = "down"
            fm_body = str(exc)

        direct_fallback_available = direct_pcc_available()
        if fm_status == "pcc_unavailable" and direct_fallback_available:
            fm_status = "ok"
            pcc_available = True

        status = 200 if fm_status == "ok" else 503
        self._send_json(status, {
            "proxy": "ok",
            "model": MODEL,
            "model_available": pcc_available,
            "direct_fallback": direct_fallback_available,
            "fm": {
                "status": fm_status,
                "base_url": FM_BASE_URL,
                "health": fm_body
            }
        })

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self._send_json(404, {"error": {"type": "not_found", "message": "Unknown endpoint."}})
            return
        if not self._authorized():
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": {"type": "bad_request", "message": "Invalid Content-Length."}})
            return

        body = self.rfile.read(content_length)
        try:
            payload = json.loads(body.decode("utf-8"))
        except Exception:
            self._send_json(400, {"error": {"type": "bad_request", "message": "Request body must be valid JSON."}})
            return

        payload["model"] = payload.get("model") or MODEL
        payload["stream"] = False

        request = urllib.request.Request(
            FM_BASE_URL + "/v1/chat/completions",
            data=json_bytes(payload),
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                response_body = response.read()
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)
        except urllib.error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="replace")
            if DIRECT_FALLBACK and MODEL == "pcc" and (
                "unavailable" in error_body.lower() or "not available" in error_body.lower()
            ):
                try:
                    prompt = messages_to_prompt(payload.get("messages"))
                    if not prompt:
                        raise RuntimeError("Request did not include any chat message content.")
                    self._send_json(200, openai_chat_response(direct_pcc_response(prompt)))
                    return
                except Exception as fallback_exc:
                    self._send_json(503, {
                        "error": {
                            "type": "pcc_unavailable",
                            "message": "PCC is unavailable from fm serve and direct fm fallback failed.",
                            "status": 503,
                            "body": error_body,
                            "fallback_detail": str(fallback_exc)
                        }
                    })
                    return
            self._send_json(exc.code, self._classified_error(exc.code, error_body))
        except Exception as exc:
            self._send_json(503, {
                "error": {
                    "type": "fm_unavailable",
                    "message": "fm serve is down or unreachable.",
                    "detail": str(exc)
                }
            })

    def _classified_error(self, status, body):
        lowered = body.lower()
        error_type = "fm_error"
        message = body or "fm serve returned an error."
        if "quota" in lowered or "rate limit" in lowered:
            error_type = "quota_exhausted"
            message = "PCC quota is exhausted or rate-limited."
        elif "unavailable" in lowered or "not available" in lowered or "pcc" in lowered:
            error_type = "pcc_unavailable"
            message = "PCC is unavailable from fm serve."
        return {"error": {"type": error_type, "message": message, "status": status, "body": body}}


httpd = ThreadingHTTPServer((HOST, PORT), GatewayHandler)
print(f"Proxy listening on http://{HOST}:{PORT}")
httpd.serve_forever()
PY
