#!/usr/bin/env bash
#
# End-to-end setup for the Databricks Claude agent sample.
#
# Automates from an empty subscription and reuses a valid repo .env PAT on reruns:
#   1. Resource group
#   2. Azure Databricks workspace
#   3. Databricks PAT (via your Microsoft Entra ID login) + .env
#   4. Serving-endpoint verification
#   5. Model connection test through the supported OpenAI-compatible route,
#      plus the native Anthropic Messages API for Claude
#   6. (optional) a full run of src/agent_sample.py against a working endpoint
#
# Requirements: az with the Databricks extension (logged in: `az login`), curl,
# and a project virtualenv at .venv created with Python 3.10 or newer.
#
# Usage:
#   scripts/setup_databricks_claude.sh
#   RG=my-rg LOCATION=koreacentral WORKSPACE=my-ws scripts/setup_databricks_claude.sh
#
# Configurable via environment variables (defaults shown):
RG="${RG:-rg-databricks-claude}"
LOCATION="${LOCATION:-eastus2}"
WORKSPACE="${WORKSPACE:-ws-databricks-claude}"
SKU="${SKU:-premium}"
ENDPOINT_EXPLICIT=0
if [ -n "${ENDPOINT:-}" ] || [ -n "${DATABRICKS_SERVING_ENDPOINT:-}" ]; then
  ENDPOINT_EXPLICIT=1
fi
FAST_ENDPOINT_EXPLICIT=0
if [ -n "${DATABRICKS_FAST_ENDPOINT:-}" ]; then
  FAST_ENDPOINT_EXPLICIT=1
fi
MODELS_EXPLICIT=0
if [ -n "${DATABRICKS_MODELS:-}" ]; then
  MODELS_EXPLICIT=1
fi
ENDPOINT="${ENDPOINT:-${DATABRICKS_SERVING_ENDPOINT:-databricks-claude-opus-4-8}}"  # target model
DATABRICKS_FAST_ENDPOINT="${DATABRICKS_FAST_ENDPOINT:-}"     # optional Haiku/lightweight background model
DATABRICKS_MODELS="${DATABRICKS_MODELS:-}"                   # optional Claude Code model aliases
FALLBACK="${FALLBACK:-databricks-meta-llama-3-3-70b-instruct}"  # proves pipeline
PAT_LIFETIME_SECONDS="${PAT_LIFETIME_SECONDS:-7776000}"    # 90 days
ROTATE_PAT="${ROTATE_PAT:-0}"                              # 1 creates a new PAT
RUN_AGENT="${RUN_AGENT:-1}"                                 # run the sample at the end

# Microsoft Entra application ID for the AzureDatabricks login service (fixed value).
DBX_AAD_RESOURCE="2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PY="$ROOT/.venv/bin/python"

c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'
c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'
log()  { printf "%s==>%s %s\n" "$c_blue"  "$c_reset" "$*"; }
ok()   { printf "%s ok %s %s\n" "$c_green" "$c_reset" "$*"; }
warn() { printf "%s[!]%s %s\n"  "$c_yellow" "$c_reset" "$*"; }
die()  { printf "%s[x]%s %s\n"  "$c_red"   "$c_reset" "$*" >&2; exit 1; }

aad_token() { az account get-access-token --resource "$DBX_AAD_RESOURCE" --query accessToken -o tsv; }

curl_with_bearer() {
  local token="$1"
  shift
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - "$@"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

load_existing_config() {
  local line key value
  EXISTING_HOST=""
  EXISTING_TOKEN=""
  EXISTING_ENDPOINT=""
  EXISTING_FAST_ENDPOINT=""
  EXISTING_MODELS=""
  [ -f "$ROOT/.env" ] || return 0

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
      DATABRICKS_HOST) EXISTING_HOST="$value" ;;
      DATABRICKS_TOKEN) EXISTING_TOKEN="$value" ;;
      DATABRICKS_SERVING_ENDPOINT) EXISTING_ENDPOINT="$value" ;;
      DATABRICKS_FAST_ENDPOINT) EXISTING_FAST_ENDPOINT="$value" ;;
      DATABRICKS_MODELS) EXISTING_MODELS="$value" ;;
    esac
  done < "$ROOT/.env"
}

token_validation_code() {
  local token="$1" code
  code="$(curl_with_bearer "$token" -sS -o /dev/null -w "%{http_code}" \
    "$HOST/api/2.0/preview/scim/v2/Me" 2>/dev/null || true)"
  printf "%s" "${code:-000}"
}

# ---------------------------------------------------------------------------
log "0/6 Preflight"
command -v az >/dev/null || die "az CLI not found. Install Azure CLI and run 'az login'."
command -v curl >/dev/null || die "curl is required."
az account show >/dev/null 2>&1 || die "Not logged in. Run 'az login' first."
az extension show --name databricks >/dev/null 2>&1 ||
  die "Azure CLI Databricks extension not found. Run: az extension add --name databricks --upgrade"
[ -x "$PY" ] ||
  die "venv not found at .venv. Create it with a Python 3.10+ interpreter as documented in README.md."
"$PY" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' ||
  die "Python 3.10 or newer is required in .venv."
SUB_NAME="$(az account show --query name -o tsv)"
ok "az logged in — subscription: $SUB_NAME"

# ---------------------------------------------------------------------------
log "1/6 Resource group '$RG' ($LOCATION)"
if az group show -n "$RG" >/dev/null 2>&1; then
  ok "resource group already exists"
else
  az group create -n "$RG" -l "$LOCATION" -o none
  ok "resource group created"
fi

# ---------------------------------------------------------------------------
log "2/6 Databricks workspace '$WORKSPACE'"
if az databricks workspace show -g "$RG" -n "$WORKSPACE" >/dev/null 2>&1; then
  ok "workspace already exists"
else
  warn "creating workspace (this can take several minutes)…"
  az databricks workspace create -g "$RG" -n "$WORKSPACE" -l "$LOCATION" --sku "$SKU" -o none
  ok "workspace created"
fi
HOST_BARE="$(az databricks workspace show -g "$RG" -n "$WORKSPACE" --query workspaceUrl -o tsv)"
HOST="https://$HOST_BARE"
ok "workspace URL: $HOST"

load_existing_config
EXISTING_CONFIG_MATCHES=0
if [ "${EXISTING_HOST%/}" = "$HOST" ]; then
  EXISTING_CONFIG_MATCHES=1
  if [ "$ENDPOINT_EXPLICIT" = "0" ] && [ -n "$EXISTING_ENDPOINT" ]; then
    ENDPOINT="$EXISTING_ENDPOINT"
  fi
  if [ "$FAST_ENDPOINT_EXPLICIT" = "0" ] && [ -n "$EXISTING_FAST_ENDPOINT" ]; then
    DATABRICKS_FAST_ENDPOINT="$EXISTING_FAST_ENDPOINT"
  fi
  if [ "$MODELS_EXPLICIT" = "0" ] && [ -n "$EXISTING_MODELS" ]; then
    DATABRICKS_MODELS="$EXISTING_MODELS"
  fi
fi

# ---------------------------------------------------------------------------
log "3/6 Databricks PAT + .env"
TOKEN=""
TOKEN_ACTION="created"
if [ "$ROTATE_PAT" != "1" ] && [ "$EXISTING_CONFIG_MATCHES" = "1" ]; then
  if [ -n "$EXISTING_TOKEN" ]; then
    VALIDATION_CODE="$(token_validation_code "$EXISTING_TOKEN")"
    case "$VALIDATION_CODE" in
      200)
        TOKEN="$EXISTING_TOKEN"
        TOKEN_ACTION="reused"
        ok "reusing the valid PAT already stored in .env"
        ;;
      401)
        warn "the PAT in .env is invalid or expired; creating a replacement"
        ;;
      *)
        die "Could not verify the PAT in .env (HTTP $VALIDATION_CODE). Retry when the workspace is reachable; use ROTATE_PAT=1 only when you intentionally want a new token."
        ;;
    esac
  fi
fi

if [ -z "$TOKEN" ]; then
  TOKEN="$(curl_with_bearer "$(aad_token)" -sS -X POST "$HOST/api/2.0/token/create" \
    -H "Content-Type: application/json" \
    -d "{\"comment\":\"agent-sample-setup\",\"lifetime_seconds\":$PAT_LIFETIME_SECONDS}" \
    | "$PY" -c "import sys,json; print(json.load(sys.stdin).get('token_value',''))")"
  [ -n "$TOKEN" ] || die "Failed to create a PAT. Ensure token creation is enabled and you have workspace access."
  ok "created a new PAT (ROTATE_PAT=$ROTATE_PAT)"
fi
OLD_UMASK="$(umask)"
umask 077
cat > "$ROOT/.env" <<EOF
# Azure Databricks workspace URL (스킴 포함)
DATABRICKS_HOST=$HOST

# Databricks Model Serving 엔드포인트 이름
DATABRICKS_SERVING_ENDPOINT=$ENDPOINT
EOF
if [ -n "$DATABRICKS_FAST_ENDPOINT" ]; then
  cat >> "$ROOT/.env" <<EOF

# Claude Code Haiku/lightweight background model
DATABRICKS_FAST_ENDPOINT=$DATABRICKS_FAST_ENDPOINT
EOF
fi
if [ -n "$DATABRICKS_MODELS" ]; then
  cat >> "$ROOT/.env" <<EOF

# Claude Code /model preset mappings
DATABRICKS_MODELS="$DATABRICKS_MODELS"
EOF
fi
cat >> "$ROOT/.env" <<EOF

# Databricks Personal Access Token (PAT)
DATABRICKS_TOKEN=$TOKEN
EOF
chmod 600 "$ROOT/.env"
umask "$OLD_UMASK"
ok ".env written (HOST + $ENDPOINT + $TOKEN_ACTION PAT). PAT length: ${#TOKEN}"
warn "This PAT is for local development. Prefer service-principal OAuth M2M in production."

# ---------------------------------------------------------------------------
log "4/6 Verify serving endpoints"
EP_JSON="$(curl_with_bearer "$TOKEN" -sS "$HOST/api/2.0/serving-endpoints")"
echo "$EP_JSON" | "$PY" -c "
import sys,json
d=json.load(sys.stdin); eps={e['name']:(e.get('state') or {}).get('ready') for e in d.get('endpoints',[])}
for name in ['$ENDPOINT','$FALLBACK']:
    print(f'  {name}: {eps.get(name, \"NOT FOUND\")}')
"

# ---------------------------------------------------------------------------
SMOKE_FILE="$(mktemp "${TMPDIR:-/tmp}/databricks-smoke.XXXXXX")"
ANTHROPIC_SMOKE_FILE="$(mktemp "${TMPDIR:-/tmp}/databricks-anthropic-smoke.XXXXXX")"
cleanup_smoke_files() {
  rm -f "$SMOKE_FILE" "$ANTHROPIC_SMOKE_FILE"
}
trap cleanup_smoke_files EXIT

# Smoke-test one model through the OpenAI-compatible Foundation Model API.
smoke() {
  local ep="$1"
  curl_with_bearer "$TOKEN" -sS -o "$SMOKE_FILE" -w "%{http_code}" -X POST \
    "$HOST/serving-endpoints/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$ep\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":10}"
}

# Smoke-test Claude through the native Anthropic Messages API used by Claude Code.
smoke_anthropic() {
  local ep="$1"
  curl_with_bearer "$TOKEN" -sS -o "$ANTHROPIC_SMOKE_FILE" -w "%{http_code}" -X POST \
    "$HOST/serving-endpoints/anthropic/v1/messages" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{\"model\":\"$ep\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":10}"
}

log "5/6 Model connection test"
WORKING_ENDPOINT=""
CODE="$(smoke "$ENDPOINT")"
if [ "$CODE" = "200" ]; then
  REPLY="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['choices'][0]['message']['content'])" "$SMOKE_FILE")"
  ok "OpenAI-compatible route for '$ENDPOINT' responded: $REPLY"
  WORKING_ENDPOINT="$ENDPOINT"
  NATIVE_CODE="$(smoke_anthropic "$ENDPOINT")"
  if [ "$NATIVE_CODE" = "200" ]; then
    NATIVE_TYPE="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1])).get('type',''))" "$ANTHROPIC_SMOKE_FILE")"
    ok "native Anthropic route responded with type='$NATIVE_TYPE'"
  else
    warn "native Anthropic route failed for '$ENDPOINT' (HTTP $NATIVE_CODE)"
  fi
else
  MSG="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1])).get('message',''))" "$SMOKE_FILE" 2>/dev/null || true)"
  warn "target '$ENDPOINT' -> HTTP $CODE: $MSG"
  if echo "$MSG" | grep -q "rate limit of 0"; then
    cat <<EOF
    ────────────────────────────────────────────────────────────
    Claude의 유효 한도가 0으로 반환됐습니다. 일반 사용량 초과(429)와 다르며,
    모델/리전 가용성, cross-Geo 설정, endpoint·사용자 rate limit,
    또는 계정별 용량 활성화 상태를 확인해야 합니다.
    Databricks 자체 모델을 아래에서 호출해 인증과 API 경로를 별도로 검증합니다.
    ────────────────────────────────────────────────────────────
EOF
  fi
  log "    trying Databricks-hosted fallback '$FALLBACK' to prove the pipeline…"
  CODE="$(smoke "$FALLBACK")"
  if [ "$CODE" = "200" ]; then
    REPLY="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['choices'][0]['message']['content'])" "$SMOKE_FILE")"
    ok "fallback '$FALLBACK' responded: $REPLY  (auth + path + PAT all verified)"
    WORKING_ENDPOINT="$FALLBACK"
  else
    warn "fallback '$FALLBACK' also failed (HTTP $CODE)"
  fi
fi
cleanup_smoke_files
trap - EXIT

# ---------------------------------------------------------------------------
log "6/6 Agent sample run"
if [ "$RUN_AGENT" = "1" ] && [ -n "$WORKING_ENDPOINT" ]; then
  ok "running src/agent_sample.py against '$WORKING_ENDPOINT'"
  echo "" | DATABRICKS_SERVING_ENDPOINT="$WORKING_ENDPOINT" "$PY" src/agent_sample.py
else
  warn "skipped (RUN_AGENT=$RUN_AGENT, working_endpoint='${WORKING_ENDPOINT:-none}')"
fi

echo
ok "Done. Workspace: $HOST"
if [ "$WORKING_ENDPOINT" = "$ENDPOINT" ]; then
  ok "Claude endpoint '$ENDPOINT' is live — run: .venv/bin/python src/agent_sample.py"
else
  warn "Claude '$ENDPOINT' is unavailable; review region, cross-Geo, rate limits, permissions, and account capacity."
fi
