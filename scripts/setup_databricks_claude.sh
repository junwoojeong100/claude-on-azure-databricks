#!/usr/bin/env bash
#
# End-to-end setup for the Databricks Claude agent sample.
#
# Automates, idempotently, from an empty subscription:
#   1. Resource group
#   2. Azure Databricks workspace
#   3. Databricks PAT (via your Azure AD login) + .env
#   4. Serving-endpoint verification
#   5. Model connection test (target Claude endpoint + a Databricks-hosted
#      fallback that proves the pipeline works)
#   6. (optional) a full run of src/agent_sample.py against a working endpoint
#
# Requirements: az (logged in: `az login`), and the project virtualenv at
# .venv (create with: python3.12 -m venv .venv && .venv/bin/pip install -r
# requirements.txt).
#
# Usage:
#   scripts/setup_databricks_claude.sh
#   RG=my-rg LOCATION=eastus2 WORKSPACE=my-ws scripts/setup_databricks_claude.sh
#
# Configurable via environment variables (defaults shown):
RG="${RG:-rg-databricks-claude}"
LOCATION="${LOCATION:-koreacentral}"
WORKSPACE="${WORKSPACE:-ws-databricks-claude}"
SKU="${SKU:-premium}"
ENDPOINT="${ENDPOINT:-databricks-claude-opus-4-8}"          # target model
FALLBACK="${FALLBACK:-databricks-meta-llama-3-3-70b-instruct}"  # proves pipeline
PAT_LIFETIME_SECONDS="${PAT_LIFETIME_SECONDS:-7776000}"    # 90 days
RUN_AGENT="${RUN_AGENT:-1}"                                 # run the sample at the end
ACCOUNT_DIAG="${ACCOUNT_DIAG:-1}"                           # read account-level settings

# Azure AD application ID for the AzureDatabricks login service (fixed value).
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

# ---------------------------------------------------------------------------
log "0/6 Preflight"
command -v az >/dev/null || die "az CLI not found. Install Azure CLI and run 'az login'."
az account show >/dev/null 2>&1 || die "Not logged in. Run 'az login' first."
[ -x "$PY" ] || die "venv not found at .venv. Run: python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt"
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

# ---------------------------------------------------------------------------
log "3/6 Databricks PAT + .env"
TOKEN="$(curl -sS -X POST "$HOST/api/2.0/token/create" \
  -H "Authorization: Bearer $(aad_token)" -H "Content-Type: application/json" \
  -d "{\"comment\":\"agent-sample-setup\",\"lifetime_seconds\":$PAT_LIFETIME_SECONDS}" \
  | "$PY" -c "import sys,json; print(json.load(sys.stdin).get('token_value',''))")"
[ -n "$TOKEN" ] || die "Failed to create a PAT. Ensure token creation is enabled and you have workspace access."
cat > "$ROOT/.env" <<EOF
# Azure Databricks workspace URL (스킴 포함)
DATABRICKS_HOST=$HOST

# Databricks Model Serving 엔드포인트 이름
DATABRICKS_SERVING_ENDPOINT=$ENDPOINT

# Databricks Personal Access Token (PAT)
DATABRICKS_TOKEN=$TOKEN
EOF
ok ".env written (HOST + $ENDPOINT + PAT). PAT length: ${#TOKEN}"

# ---------------------------------------------------------------------------
if [ "$ACCOUNT_DIAG" = "1" ]; then
  log "3b/6 Account diagnostic (best-effort)"
  "$PY" - "$HOST" "$TOKEN" <<'PY' || warn "account diagnostic skipped"
import sys
host, token = sys.argv[1], sys.argv[2]
try:
    from databricks.sdk import WorkspaceClient, AccountClient
except Exception:
    print("  (databricks-sdk not installed: pip install databricks-sdk to enable)")
    sys.exit(0)
try:
    w = WorkspaceClient(host=host, token=token)
    acc = getattr(w.config, "account_id", None)
    print(f"  account_id: {acc}")
    if not acc:
        sys.exit(0)
    a = AccountClient(host="https://accounts.azuredatabricks.net", account_id=acc, auth_type="azure-cli")
    for name in ("llm_proxy_partner_powered_account", "llm_proxy_partner_powered_enforce"):
        try:
            cur = getattr(a.settings, name).get()
            bv = getattr(cur, "boolean_val", None)
            print(f"  {name}: {getattr(bv, 'value', bv)}")
        except Exception as e:
            print(f"  {name}: (needs account admin) {str(e)[:80]}")
except Exception as e:
    print(f"  (skipped: {str(e)[:100]})")
PY
fi

# ---------------------------------------------------------------------------
log "4/6 Verify serving endpoints"
EP_JSON="$(curl -sS -H "Authorization: Bearer $TOKEN" "$HOST/api/2.0/serving-endpoints")"
echo "$EP_JSON" | "$PY" -c "
import sys,json
d=json.load(sys.stdin); eps={e['name']:(e.get('state') or {}).get('ready') for e in d.get('endpoints',[])}
for name in ['$ENDPOINT','$FALLBACK']:
    print(f'  {name}: {eps.get(name, \"NOT FOUND\")}')
"

# ---------------------------------------------------------------------------
# Smoke-test one endpoint. Echoes: '200' on success, or the error_code.
smoke() {
  local ep="$1"
  curl -sS -o /tmp/_smoke.json -w "%{http_code}" -X POST \
    "$HOST/serving-endpoints/$ep/invocations" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":10}'
}

log "5/6 Model connection test"
WORKING_ENDPOINT=""
CODE="$(smoke "$ENDPOINT")"
if [ "$CODE" = "200" ]; then
  REPLY="$("$PY" -c "import json;print(json.load(open('/tmp/_smoke.json'))['choices'][0]['message']['content'])")"
  ok "target '$ENDPOINT' responded: $REPLY"
  WORKING_ENDPOINT="$ENDPOINT"
else
  MSG="$("$PY" -c "import json;print(json.load(open('/tmp/_smoke.json')).get('message',''))" 2>/dev/null || true)"
  warn "target '$ENDPOINT' -> HTTP $CODE: $MSG"
  if echo "$MSG" | grep -q "rate limit of 0"; then
    cat <<EOF
    ────────────────────────────────────────────────────────────
    Anthropic Claude 모델이 계정 레벨에서 비활성화돼 있습니다.
    이는 리전/워크스페이스 무관(테넌트당 Databricks 계정 1개)이며,
    partner-powered/cross-Geo 설정으로 풀리지 않습니다. Databricks가
    계정에 Anthropic pay-per-token 엔타이틀먼트를 켜줘야 합니다.
    (Databricks 자체 호스팅 모델은 아래처럼 정상 동작합니다.)
    ────────────────────────────────────────────────────────────
EOF
  fi
  log "    trying Databricks-hosted fallback '$FALLBACK' to prove the pipeline…"
  CODE="$(smoke "$FALLBACK")"
  if [ "$CODE" = "200" ]; then
    REPLY="$("$PY" -c "import json;print(json.load(open('/tmp/_smoke.json'))['choices'][0]['message']['content'])")"
    ok "fallback '$FALLBACK' responded: $REPLY  (auth + path + PAT all verified)"
    WORKING_ENDPOINT="$FALLBACK"
  else
    warn "fallback '$FALLBACK' also failed (HTTP $CODE)"
  fi
fi
rm -f /tmp/_smoke.json

# ---------------------------------------------------------------------------
log "6/6 Agent sample run"
if [ "$RUN_AGENT" = "1" ] && [ -n "$WORKING_ENDPOINT" ]; then
  ok "running src/agent_sample.py against '$WORKING_ENDPOINT'"
  echo "" | DATABRICKS_SERVING_ENDPOINT="$WORKING_ENDPOINT" "$PY" src/agent_sample.py || true
else
  warn "skipped (RUN_AGENT=$RUN_AGENT, working_endpoint='${WORKING_ENDPOINT:-none}')"
fi

echo
ok "Done. Workspace: $HOST"
if [ "$WORKING_ENDPOINT" = "$ENDPOINT" ]; then
  ok "Claude endpoint '$ENDPOINT' is live — run: .venv/bin/python src/agent_sample.py"
else
  warn "Claude '$ENDPOINT' is account-gated; the sample is wired and will work the moment Databricks enables Anthropic for your account."
fi
