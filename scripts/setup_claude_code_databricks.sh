#!/usr/bin/env bash
#
# Configure Claude Code to call Azure Databricks' native Anthropic Messages API.
#
# No local proxy is required:
#
#   Claude Code ──(Anthropic /v1/messages)──► Azure Databricks Model Serving
#                    /serving-endpoints/anthropic
#
# The script:
#   1. Loads Databricks credentials from .env or the environment.
#   2. Verifies the native Anthropic endpoint.
#   3. Stores the Databricks token in a 0600 file outside Claude settings.
#   4. Configures Claude Code with an apiKeyHelper and model aliases.
#   5. Disables the legacy LiteLLM auto-start service if present.
#   6. Runs a Claude Code end-to-end test.
#
# Usage:
#   scripts/setup_claude_code_databricks.sh
#
#   DATABRICKS_HOST=https://adb-xxx.azuredatabricks.net \
#   DATABRICKS_TOKEN=dapi... \
#   DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8 \
#   scripts/setup_claude_code_databricks.sh
#
# Configurable environment variables:
#   STATE_DIR                 Credential/helper directory
#                             (default: ~/.claude-databricks)
#   CLAUDE_SETTINGS           Claude Code settings path
#                             (default: ~/.claude/settings.json)
#   ENV_FILE                  Credential source (default: repo .env)
#   DATABRICKS_FAST_ENDPOINT  Claude Code small/fast model
#   DATABRICKS_MODELS         Models used to map /model family presets
#   LEGACY_LAUNCHD_LABEL      Previous LiteLLM launchd label

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${STATE_DIR:-${PROXY_DIR:-$HOME/.claude-databricks}}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
LEGACY_LAUNCHD_LABEL="${LEGACY_LAUNCHD_LABEL:-com.databricks.claude-proxy}"

c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'
c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'
log()  { printf "%s==>%s %s\n" "$c_blue"   "$c_reset" "$*"; }
ok()   { printf "%s ok %s %s\n" "$c_green"  "$c_reset" "$*"; }
warn() { printf "%s[!]%s %s\n"  "$c_yellow" "$c_reset" "$*"; }
die()  { printf "%s[x]%s %s\n"  "$c_red"    "$c_reset" "$*" >&2; exit 1; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

curl_with_bearer() {
  local token="$1"
  shift
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - "$@"
}

load_env_file() {
  local line key value
  [ -f "$ENV_FILE" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "$line")"
    case "$line" in ""|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac

    case "$key" in
      DATABRICKS_HOST)
        [ -n "${DATABRICKS_HOST:-}" ] || DATABRICKS_HOST="$value"
        ;;
      DATABRICKS_TOKEN)
        [ -n "${DATABRICKS_TOKEN:-}" ] || DATABRICKS_TOKEN="$value"
        ;;
      DATABRICKS_SERVING_ENDPOINT)
        [ -n "${DATABRICKS_SERVING_ENDPOINT:-}" ] || DATABRICKS_SERVING_ENDPOINT="$value"
        ;;
      DATABRICKS_FAST_ENDPOINT)
        [ -n "${DATABRICKS_FAST_ENDPOINT:-}" ] || DATABRICKS_FAST_ENDPOINT="$value"
        ;;
      DATABRICKS_MODELS)
        [ -n "${DATABRICKS_MODELS:-}" ] || DATABRICKS_MODELS="$value"
        ;;
    esac
  done < "$ENV_FILE"
}

native_request() {
  local model="$1" payload response
  payload="$(printf '{"model":"%s","max_tokens":16,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}' "$model")"
  response="$(curl_with_bearer "$DATABRICKS_TOKEN" -sS \
    -w $'\n%{http_code}' \
    -X POST "$ANTHROPIC_BASE_URL/v1/messages" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "$payload")"
  NATIVE_HTTP_CODE="${response##*$'\n'}"
  NATIVE_BODY="${response%$'\n'*}"

  [ "$NATIVE_HTTP_CODE" = "200" ] &&
    printf "%s" "$NATIVE_BODY" | grep -Eq '"type"[[:space:]]*:[[:space:]]*"message"'
}

disable_legacy_proxy() {
  local changed=0 plist unit

  if [ "$(uname -s)" = "Darwin" ]; then
    plist="$HOME/Library/LaunchAgents/$LEGACY_LAUNCHD_LABEL.plist"
    if [ -f "$plist" ]; then
      launchctl unload "$plist" >/dev/null 2>&1 || true
      rm -f "$plist"
      changed=1
    else
      launchctl remove "$LEGACY_LAUNCHD_LABEL" >/dev/null 2>&1 || true
    fi
  elif command -v systemctl >/dev/null 2>&1; then
    unit="$HOME/.config/systemd/user/claude-databricks.service"
    if [ -f "$unit" ] && grep -Fq "start-proxy.sh" "$unit"; then
      if systemctl --user disable --now claude-databricks.service >/dev/null 2>&1; then
        rm -f "$unit"
        systemctl --user daemon-reload >/dev/null 2>&1 ||
          warn "legacy unit was removed, but systemd daemon-reload failed"
        changed=1
      else
        warn "could not stop the legacy systemd service; leaving $unit in place"
      fi
    fi
  fi

  if [ "$changed" = "1" ]; then
    ok "disabled the legacy LiteLLM auto-start service"
  elif [ -f "$STATE_DIR/config.yaml" ] || [ -d "$STATE_DIR/.venv" ]; then
    warn "legacy LiteLLM files remain in $STATE_DIR but are no longer used"
  fi
}

log "1/6 Load Databricks credentials"
load_env_file
: "${DATABRICKS_HOST:?DATABRICKS_HOST is required (in .env or the environment)}"
: "${DATABRICKS_TOKEN:?DATABRICKS_TOKEN is required (in .env or the environment)}"

ENDPOINT="${DATABRICKS_SERVING_ENDPOINT:-databricks-claude-opus-4-8}"
FAST_ENDPOINT="${DATABRICKS_FAST_ENDPOINT:-databricks-claude-haiku-4-5}"
MODELS="${DATABRICKS_MODELS:-databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5}"
MODELS="${MODELS//,/ }"
ANTHROPIC_BASE_URL="${DATABRICKS_HOST%/}/serving-endpoints/anthropic"

ok "native Anthropic API: $ANTHROPIC_BASE_URL"
ok "default model: $ENDPOINT   small/fast: $FAST_ENDPOINT"

log "2/6 Preflight"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v claude >/dev/null 2>&1 || die "Claude Code is not installed or not on PATH"
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  die "unset ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY in this shell before setup; ambient credentials override apiKeyHelper"
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON="$(command -v python)"
else
  die "Python is required to merge Claude Code settings safely"
fi
ok "Claude Code: $(claude --version 2>/dev/null | head -1)"

log "3/6 Verify native Anthropic API"
if native_request "$ENDPOINT"; then
  ok "main model '$ENDPOINT' returned an Anthropic message"
else
  printf "%s\n" "$NATIVE_BODY" >&2
  die "native Anthropic request failed for '$ENDPOINT' (HTTP $NATIVE_HTTP_CODE)"
fi

if [ "$FAST_ENDPOINT" != "$ENDPOINT" ]; then
  if native_request "$FAST_ENDPOINT"; then
    ok "small/fast model '$FAST_ENDPOINT' returned an Anthropic message"
  else
    warn "small/fast model '$FAST_ENDPOINT' failed (HTTP $NATIVE_HTTP_CODE); using '$ENDPOINT'"
    FAST_ENDPOINT="$ENDPOINT"
  fi
fi

VALID_MODELS="$ENDPOINT $FAST_ENDPOINT"
for model in $MODELS; do
  [ "$model" = "$ENDPOINT" ] && continue
  [ "$model" = "$FAST_ENDPOINT" ] && continue
  if native_request "$model"; then
    ok "selectable model '$model' returned an Anthropic message"
    VALID_MODELS="$VALID_MODELS $model"
  else
    warn "selectable model '$model' failed validation (HTTP $NATIVE_HTTP_CODE); using a validated family fallback"
  fi
done

log "4/6 Store credential helper"
mkdir -p "$STATE_DIR"
STATE_DIR="$(cd "$STATE_DIR" && pwd)"
chmod 700 "$STATE_DIR"
OLD_UMASK="$(umask)"
umask 077
cat > "$STATE_DIR/.env" <<EOF
# Used only by the Claude Code apiKeyHelper. Contains a Databricks credential.
DATABRICKS_TOKEN=$DATABRICKS_TOKEN
EOF
cat > "$STATE_DIR/get-token.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TOKEN_FILE="$(cd "$(dirname "$0")" && pwd)/.env"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    DATABRICKS_TOKEN=*)
      printf "%s" "${line#*=}"
      exit 0
      ;;
  esac
done < "$TOKEN_FILE"
echo "DATABRICKS_TOKEN is missing from $TOKEN_FILE" >&2
exit 1
EOF
chmod 600 "$STATE_DIR/.env"
chmod 700 "$STATE_DIR/get-token.sh"
umask "$OLD_UMASK"
ok "credential stored in $STATE_DIR/.env (0600)"

log "5/6 Configure Claude Code"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
if [ -f "$CLAUDE_SETTINGS" ]; then
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  ok "backed up existing Claude settings"
fi

DEFAULT_OPUS=""; DEFAULT_SONNET=""; DEFAULT_HAIKU=""
for model in $VALID_MODELS; do
  case "$model" in
    *opus*)   [ -n "$DEFAULT_OPUS" ]   || DEFAULT_OPUS="$model" ;;
    *sonnet*) [ -n "$DEFAULT_SONNET" ] || DEFAULT_SONNET="$model" ;;
    *haiku*)  [ -n "$DEFAULT_HAIKU" ]  || DEFAULT_HAIKU="$model" ;;
  esac
done
[ -n "$DEFAULT_OPUS" ] || DEFAULT_OPUS="$ENDPOINT"
[ -n "$DEFAULT_SONNET" ] || DEFAULT_SONNET="$ENDPOINT"
[ -n "$DEFAULT_HAIKU" ] || DEFAULT_HAIKU="$FAST_ENDPOINT"

CLAUDE_SETTINGS="$CLAUDE_SETTINGS" \
TOKEN_HELPER="$STATE_DIR/get-token.sh" \
ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
ENDPOINT="$ENDPOINT" \
FAST_ENDPOINT="$FAST_ENDPOINT" \
DEFAULT_OPUS="$DEFAULT_OPUS" \
DEFAULT_SONNET="$DEFAULT_SONNET" \
DEFAULT_HAIKU="$DEFAULT_HAIKU" \
"$PYTHON" - <<'PY'
import json
import os
import shlex
from pathlib import Path

path = Path(os.environ["CLAUDE_SETTINGS"])
if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit(f"{path} must contain a JSON object")

env = data.get("env")
if env is None:
    env = {}
elif not isinstance(env, dict):
    raise SystemExit(f"{path}: 'env' must be a JSON object")

env.pop("ANTHROPIC_AUTH_TOKEN", None)
env.pop("ANTHROPIC_API_KEY", None)
env.pop("ANTHROPIC_DEFAULT_OPUS_MODEL", None)
env.pop("ANTHROPIC_DEFAULT_SONNET_MODEL", None)
env.pop("ANTHROPIC_DEFAULT_HAIKU_MODEL", None)
env.update(
    {
        "ANTHROPIC_BASE_URL": os.environ["ANTHROPIC_BASE_URL"],
        "ANTHROPIC_MODEL": os.environ["ENDPOINT"],
        "ANTHROPIC_SMALL_FAST_MODEL": os.environ["FAST_ENDPOINT"],
        "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
        "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "900000",
    }
)

permissions = data.get("permissions")
if permissions is None:
    permissions = {}
elif not isinstance(permissions, dict):
    raise SystemExit(f"{path}: 'permissions' must be a JSON object")

deny = permissions.get("deny")
if deny is None:
    deny = []
elif not isinstance(deny, list):
    raise SystemExit(f"{path}: 'permissions.deny' must be a JSON array")
if "WebSearch" not in deny:
    deny.append("WebSearch")
permissions["deny"] = deny

for source, target in (
    ("DEFAULT_OPUS", "ANTHROPIC_DEFAULT_OPUS_MODEL"),
    ("DEFAULT_SONNET", "ANTHROPIC_DEFAULT_SONNET_MODEL"),
    ("DEFAULT_HAIKU", "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
):
    value = os.environ.get(source, "")
    if value:
        env[target] = value

data["apiKeyHelper"] = shlex.quote(os.environ["TOKEN_HELPER"])
data["env"] = env
data["permissions"] = permissions
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
ok "configured direct Databricks access in $CLAUDE_SETTINGS"
disable_legacy_proxy

log "6/6 Claude Code end-to-end test"
VERIFY_DIR="$(mktemp -d)"
cp "$CLAUDE_SETTINGS" "$VERIFY_DIR/settings.json"
set +e
CLAUDE_OUTPUT="$(
  CLAUDE_CONFIG_DIR="$VERIFY_DIR" \
  claude --model "$ENDPOINT" \
    -p "Reply with exactly: DIRECT OK" --output-format json 2>&1
)"
CLAUDE_EXIT=$?
set -e
rm -rf "$VERIFY_DIR"

if [ "$CLAUDE_EXIT" -ne 0 ] || ! printf "%s" "$CLAUDE_OUTPUT" | "$PYTHON" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
raise SystemExit(0 if not data.get("is_error") and "DIRECT OK" in str(data.get("result", "")).upper() else 1)
'; then
  printf "%s\n" "$CLAUDE_OUTPUT" >&2
  die "Claude Code direct Databricks test failed"
fi
ok "Claude Code reached Databricks directly without LiteLLM"

echo
ok "Done."
echo "  - Start Claude Code:  claude"
echo "  - Switch model:      /model"
echo "  - Native API:        $ANTHROPIC_BASE_URL"
echo "  - Credential helper: $STATE_DIR/get-token.sh"
echo "  - Legacy LiteLLM files, if any, are inert and can be removed after review."
