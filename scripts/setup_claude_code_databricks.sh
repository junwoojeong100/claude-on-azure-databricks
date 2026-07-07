#!/usr/bin/env bash
#
# Bridge the Claude Code CLI to an Azure Databricks-hosted Claude model.
#
# Claude Code speaks only the Anthropic Messages API (POST /v1/messages,
# Anthropic-shaped responses). Databricks Model Serving speaks the OpenAI
# Chat Completions schema at /serving-endpoints/<name>/invocations. This
# script installs a small local LiteLLM proxy that translates between the two,
# then points Claude Code at it via ~/.claude/settings.json.
#
#   Claude Code ──(/v1/messages)──► LiteLLM (127.0.0.1:PORT) ──► Databricks
#
# It is idempotent: safe to re-run. Credentials are read from the repo .env
# (or the environment) and written only to <proxy-dir>/.env with 0600 perms.
#
# Usage:
#   scripts/setup_claude_code_databricks.sh
#
#   # credentials from the environment instead of .env:
#   DATABRICKS_HOST=https://adb-xxx.azuredatabricks.net \
#   DATABRICKS_TOKEN=dapi... \
#   DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8 \
#   scripts/setup_claude_code_databricks.sh
#
#   # install without a background service (start it yourself later):
#   AUTOSTART=0 scripts/setup_claude_code_databricks.sh
#
# Configurable via environment variables (defaults shown):
PROXY_DIR="${PROXY_DIR:-$HOME/.claude-databricks}"   # where the proxy lives
PORT="${PORT:-4000}"                                  # local proxy port
MASTER_KEY="${MASTER_KEY:-sk-databricks-local}"       # local-only proxy key
AUTOSTART="${AUTOSTART:-1}"                            # 1=install a service
LAUNCHD_LABEL="${LAUNCHD_LABEL:-com.databricks.claude-proxy}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
ENDPOINT="${DATABRICKS_SERVING_ENDPOINT:-databricks-claude-opus-4-8}"
FORCE="${FORCE:-0}"                                   # 1=reinstall litellm

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'
c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'
log()  { printf "%s==>%s %s\n" "$c_blue"   "$c_reset" "$*"; }
ok()   { printf "%s ok %s %s\n" "$c_green"  "$c_reset" "$*"; }
warn() { printf "%s[!]%s %s\n"  "$c_yellow" "$c_reset" "$*"; }
die()  { printf "%s[x]%s %s\n"  "$c_red"    "$c_reset" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "1/7 Load Databricks credentials"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
  ok "loaded $ENV_FILE"
else
  warn "no $ENV_FILE — expecting DATABRICKS_HOST/DATABRICKS_TOKEN in the environment"
fi
: "${DATABRICKS_HOST:?DATABRICKS_HOST is required (in .env or the environment)}"
: "${DATABRICKS_TOKEN:?DATABRICKS_TOKEN is required (in .env or the environment)}"
ENDPOINT="${DATABRICKS_SERVING_ENDPOINT:-$ENDPOINT}"
API_BASE="${DATABRICKS_HOST%/}/serving-endpoints"
ok "endpoint: $ENDPOINT   base: $API_BASE"

# ---------------------------------------------------------------------------
log "2/7 Preflight"
command -v claude >/dev/null 2>&1 \
  && ok "claude CLI: $(claude --version 2>/dev/null | head -1)" \
  || warn "claude CLI not on PATH — install it, then re-run (setup still continues)"

if command -v uv >/dev/null 2>&1; then
  INSTALLER="uv"; ok "using uv for the Python environment"
elif command -v python3.12 >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  INSTALLER="venv"; ok "using python venv + pip"
else
  die "need either 'uv' or 'python3' to create the proxy environment"
fi

# ---------------------------------------------------------------------------
log "3/7 Proxy environment at $PROXY_DIR"
mkdir -p "$PROXY_DIR"
VENV="$PROXY_DIR/.venv"
if [ -x "$VENV/bin/litellm" ] && [ "$FORCE" != "1" ]; then
  ok "litellm already installed (FORCE=1 to reinstall)"
else
  if [ "$INSTALLER" = "uv" ]; then
    [ -d "$VENV" ] || uv venv "$VENV" --python 3.12
    uv pip install --python "$VENV/bin/python" --quiet "litellm[proxy]"
  else
    PYBIN="$(command -v python3.12 || command -v python3)"
    [ -d "$VENV" ] || "$PYBIN" -m venv "$VENV"
    "$VENV/bin/python" -m pip install --quiet --upgrade pip
    "$VENV/bin/python" -m pip install --quiet "litellm[proxy]"
  fi
  ok "installed litellm[proxy]"
fi

# ---------------------------------------------------------------------------
log "4/7 Write proxy config, credentials, and start script"

cat > "$PROXY_DIR/config.yaml" <<EOF
# LiteLLM proxy: exposes an Anthropic /v1/messages endpoint that Claude Code
# talks to, and translates each request to the Azure Databricks serving
# endpoint "$ENDPOINT". Credentials are injected from $PROXY_DIR/.env at
# runtime (DATABRICKS_API_KEY / DATABRICKS_API_BASE); no secrets live here.
model_list:
  - model_name: $ENDPOINT
    litellm_params:
      model: databricks/$ENDPOINT
      api_key: os.environ/DATABRICKS_API_KEY
      api_base: os.environ/DATABRICKS_API_BASE
  # Catch-all: any other model name Claude Code may request (e.g. a background
  # "small/fast" model) is routed to the same Databricks endpoint.
  - model_name: "*"
    litellm_params:
      model: databricks/$ENDPOINT
      api_key: os.environ/DATABRICKS_API_KEY
      api_base: os.environ/DATABRICKS_API_BASE

litellm_settings:
  # Silently drop provider-unsupported OpenAI params instead of erroring.
  drop_params: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
ok "wrote $PROXY_DIR/config.yaml"

# Self-contained credentials for the proxy (not coupled to the repo location).
umask 077
cat > "$PROXY_DIR/.env" <<EOF
# Auto-generated by setup_claude_code_databricks.sh — contains a secret.
DATABRICKS_API_KEY=$DATABRICKS_TOKEN
DATABRICKS_API_BASE=$API_BASE
LITELLM_MASTER_KEY=$MASTER_KEY
EOF
chmod 600 "$PROXY_DIR/.env"
umask 022
ok "wrote $PROXY_DIR/.env (0600)"

cat > "$PROXY_DIR/start-proxy.sh" <<EOF
#!/usr/bin/env bash
# Start the LiteLLM proxy bridging Claude Code to Azure Databricks.
set -euo pipefail
DIR="$PROXY_DIR"
set -a
# shellcheck disable=SC1091
. "\$DIR/.env"
set +a
exec "\$DIR/.venv/bin/litellm" --config "\$DIR/config.yaml" --host 127.0.0.1 --port $PORT
EOF
chmod +x "$PROXY_DIR/start-proxy.sh"
ok "wrote $PROXY_DIR/start-proxy.sh"

# ---------------------------------------------------------------------------
log "5/7 Point Claude Code at the proxy ($CLAUDE_SETTINGS)"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
[ -f "$CLAUDE_SETTINGS" ] && cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%s)" && ok "backed up existing settings"
CLAUDE_SETTINGS="$CLAUDE_SETTINGS" PORT="$PORT" MASTER_KEY="$MASTER_KEY" ENDPOINT="$ENDPOINT" \
"$VENV/bin/python" - <<'PY'
import json, os
path = os.environ["CLAUDE_SETTINGS"]
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
env = data.get("env") or {}
env.update({
    "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{os.environ['PORT']}",
    "ANTHROPIC_AUTH_TOKEN": os.environ["MASTER_KEY"],
    "ANTHROPIC_MODEL": os.environ["ENDPOINT"],
    "ANTHROPIC_SMALL_FAST_MODEL": os.environ["ENDPOINT"],
})
data["env"] = env
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("  merged env block into", path)
PY
ok "Claude Code settings updated"

# ---------------------------------------------------------------------------
log "6/7 Start the proxy"
health() { curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/health/liveliness" 2>/dev/null || echo 000; }

start_launchd() {
  local plist="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROXY_DIR/start-proxy.sh</string>
    </array>
    <key>WorkingDirectory</key><string>$PROXY_DIR</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$PROXY_DIR/proxy.log</string>
    <key>StandardErrorPath</key><string>$PROXY_DIR/proxy.log</string>
</dict>
</plist>
EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load -w "$plist"
  ok "launchd service '$LAUNCHD_LABEL' loaded (starts on login, restarts on crash)"
}

if [ "$AUTOSTART" = "1" ]; then
  case "$(uname -s)" in
    Darwin) start_launchd ;;
    *)
      warn "auto-start service is implemented for macOS (launchd) only."
      warn "starting in the background with nohup for now; see the docs for a systemd unit."
      nohup "$PROXY_DIR/start-proxy.sh" > "$PROXY_DIR/proxy.log" 2>&1 &
      ok "proxy started (nohup, PID $!)"
      ;;
  esac
else
  warn "AUTOSTART=0 — start it yourself: $PROXY_DIR/start-proxy.sh"
fi

# ---------------------------------------------------------------------------
log "7/7 Verify"
if [ "$AUTOSTART" = "1" ]; then
  for _ in $(seq 1 30); do [ "$(health)" = "200" ] && break; sleep 1; done
  [ "$(health)" = "200" ] || { warn "proxy did not become healthy — check $PROXY_DIR/proxy.log"; exit 0; }
  ok "proxy healthy on 127.0.0.1:$PORT"
  RESP="$(curl -s "http://127.0.0.1:$PORT/v1/messages" \
    -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{\"model\":\"$ENDPOINT\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: OK\"}]}")"
  if echo "$RESP" | grep -q '"type": *"message"'; then
    ok "/v1/messages round-trip OK (native Anthropic response from Databricks)"
  else
    warn "/v1/messages test did not return an Anthropic message. Response:"
    echo "    $RESP"
  fi
fi

echo
ok "Done."
echo "  • Open a new terminal and run:  claude"
echo "  • Manual start (if service is off):  $PROXY_DIR/start-proxy.sh"
echo "  • Logs:  $PROXY_DIR/proxy.log"
echo "  • Docs:  docs/claude-code-databricks.md"
